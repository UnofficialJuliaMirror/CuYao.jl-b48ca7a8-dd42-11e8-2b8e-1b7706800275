using Yao, Yao.Boost, Yao.Intrinsics, StaticArrays, Yao.Blocks, LinearAlgebra
using Yao.Blocks: swapapply!
using Test
using CuYao
using StatsBase: Weights
#include("../src/CuYao.jl")
#using .CuYao

@testset "gpu unapply!" begin
    nbit = 6
    N = 1<<nbit
    LOC1 = SVector{2}([0, 1])
    v1 = randn(ComplexF32, N)
    vn = randn(ComplexF32, N, 333)

    for U1 in [mat(H), mat(Y), mat(Z), mat(I2), mat(P0)]
        @test unapply!(v1 |> cu, U1, (3,)) |> Vector ≈ unapply!(v1 |> copy, U1, (3,))
        @test unapply!(vn |> cu, U1, (3,)) |> Matrix ≈ unapply!(vn |> copy, U1, (3,))
    end
    # sparse matrix like P0, P1 et. al. are not implemented.
end

@testset "gpu swapapply!" begin
    nbit = 6
    N = 1<<nbit
    LOC1 = SVector{2}([0, 1])
    v1 = randn(ComplexF32, N)
    vn = randn(ComplexF32, N, 333)

    @test swapapply!(v1 |> cu, 3,5) |> Vector ≈ swapapply!(v1 |> copy, 3,5)
    @test swapapply!(vn |> cu, 3,5) |> Matrix ≈ swapapply!(vn |> copy, 3,5)
end

@testset "gpu u1apply!" begin
    nbit = 6
    N = 1<<nbit
    LOC1 = SVector{2}([0, 1])
    v1 = randn(ComplexF32, N)
    vn = randn(ComplexF32, N, 333)

    for U1 in [mat(H), mat(Y), mat(Z), mat(I2), mat(P0)]
        @test u1apply!(v1 |> cu, U1, 3) |> Vector ≈ u1apply!(v1 |> copy, U1, 3)
        @test u1apply!(vn |> cu, U1, 3) |> Matrix ≈ u1apply!(vn |> copy, U1, 3)
    end
    # sparse matrix like P0, P1 et. al. are not implemented.
end

@testset "gpu xyz-apply!" begin
    nbit = 6
    N = 1<<nbit
    LOC1 = SVector{2}([0, 1])
    v1 = randn(ComplexF32, N)
    vn = randn(ComplexF32, N, 333)

    for func in [xapply!, yapply!, zapply!, tapply!, tdagapply!, sapply!, sdagapply!]
        @test func(v1 |> cu, 3) |> Vector ≈ func(v1 |> copy, 3)
        @test func(vn |> cu, 3) |> Matrix ≈ func(vn |> copy, 3)
        @test func(v1 |> cu, [1,3,4]) |> Vector ≈ func(v1 |> copy, [1,3,4])
        @test func(vn |> cu, [1,3,4]) |> Matrix ≈ func(vn |> copy, [1,3,4])
    end
end

@testset "gpu cn-xyz-apply!" begin
    nbit = 6
    N = 1<<nbit
    LOC1 = SVector{2}([0, 1])
    v1 = randn(ComplexF32, N)
    vn = randn(ComplexF32, N, 333)

    for func in [cxapply!, cyapply!, czapply!, ctapply!, ctdagapply!, csapply!, csdagapply!]
        @test func(v1 |> cu, (4,5), (0, 1), 3) |> Vector ≈ func(v1 |> copy, (4,5), (0, 1), 3)
        @test func(vn |> cu, (4,5), (0, 1), 3) |> Matrix ≈ func(vn |> copy, (4,5), (0, 1), 3)
        @test func(v1 |> cu, 1, 1, 3) |> Vector ≈ func(v1 |> copy, 1, 1,3)
        @test func(vn |> cu, 1, 1, 3) |> Matrix ≈ func(vn |> copy, 1, 1,3)
    end
end

function loss_expect!(circuit::AbstractBlock, op::AbstractBlock)
    N = nqubits(circuit)
    function loss!(ψ::AbstractRegister, θ::Vector)
        params = parameters(circuit)
        dispatch!(circuit, θ)
        ψ |> circuit
        dispatch!!(circuit, params)
        expect(op, ψ)
    end
end

@testset "BP diff" begin
    c = put(4, 3=>Rx(0.5)) |> autodiff(:BP)
    cad = c'
    @test mat(cad) == mat(c)'

    circuit = chain(4, repeat(4, H, 1:4), put(4, 3=>Rz(0.5)) |> autodiff(:BP), control(2, 1=>X), put(4, 4=>Ry(0.2)) |> autodiff(:BP))
    op = put(4, 3=>Y)
    θ = [0.1, 0.2]
    dispatch!(circuit, θ)
    loss! = loss_expect!(circuit, op)
    ψ0 = rand_state(4) |> cu
    ψ = copy(ψ0) |> circuit

    # get gradient
    δ = ψ |> op
    backward!(δ, circuit)
    g1 = gradient(circuit)

    g2 = zero(θ)
    η = 0.01
    for i in 1:length(θ)
        θ1 = copy(θ)
        θ2 = copy(θ)
        θ1[i] -= 0.5η
        θ2[i] += 0.5η
        g2[i] = (loss!(copy(ψ0), θ2) - loss!(copy(ψ0), θ1))/η |> real
    end
    g3 = opdiff.(() -> copy(ψ0) |> circuit, collect(circuit, BPDiff), Ref(op))
    @test δ isa GPUReg
    @test ψ isa GPUReg
    @test isapprox.(g1, g2, atol=1e-5) |> all
    @test isapprox.(g2, g3, atol=1e-5) |> all
end

@testset "stat diff" begin
    nbit = 4
    f(x::Number, y::Number) = Float64(abs(x-y) < 1.5)
    x = 0:1<<nbit-1
    h = f.(x', x)
    V = StatFunctional(h)
    VF = StatFunctional{2}(f)
    prs = [1=>2, 2=>3, 3=>1]
    c = chain(4, repeat(4, H, 1:4), put(4, 3=>Rz(0.5)) |> autodiff(:BP), control(2, 1=>X), put(4, 4=>Ry(0.2)) |> autodiff(:QC))
    dispatch!(c, :random)
    dbs = collect(c, AbstractDiff)

    p0 = zero_state(nbit) |> c |> probs |> Weights
    sample0 = measure(zero_state(nbit) |> c, nshot=5000)
    loss0 = expect(V, p0)
    gradsn = numdiff.(()->expect(V, zero_state(nbit) |> c |> probs |> Weights), dbs)
    gradse = statdiff.(()->zero_state(nbit) |> c |> probs |> Weights, dbs, Ref(V), initial=p0)
    gradsf = statdiff.(()->measure(zero_state(nbit) |> c, nshot=5000), dbs, Ref(VF), initial=sample0)
    @test all(isapprox.(gradse, gradsn, atol=1e-4))
    @test norm(gradsf-gradse)/norm(gradsf) <= 0.2

    # 1D
    h = randn(1<<nbit)
    V = StatFunctional(h)
    c = chain(4, repeat(4, H, 1:4), put(4, 3=>Rz(0.5)) |> autodiff(:BP), control(2, 1=>X), put(4, 4=>Ry(0.2)) |> autodiff(:QC))
    dispatch!(c, :random)
    dbs = collect(c, AbstractDiff)

    p0 = zero_state(nbit) |> c |> probs
    loss0 = expect(V, p0 |> as_weights)
    gradsn = numdiff.(()->expect(V, zero_state(nbit) |> c |> probs |> as_weights), dbs)
    gradse = statdiff.(()->zero_state(nbit) |> c |> probs |> as_weights, dbs, Ref(V))
    @test all(isapprox.(gradse, gradsn, atol=1e-4))
end
