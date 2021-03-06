"""
Robot dance

Implements an automatic control framework to design efficient mitigation strategies
for Covid-19 based on the control of a SEIR model.

Copyright: Paulo J. S. Silva <pjssilva@unicamp.br>, 2020.
"""

using JuMP
using Ipopt
using Printf
using LinearAlgebra
using SparseArrays
import Statistics.mean

"""
    struct SEIR_Parameters

Parameters to define a SEIR model:

- tinc: incubation time (5.2 for Covid-19).
- tinf: time of infection (2.9 for Covid-19).
- rep: The natural reproduction rate of the disease, for examploe for Covid-19
  you might want to use 2.5 or a similar value.
- ndays: simulation duration.
- ncities: number of (interconnected) cities in the model.
- s1, e1, i1, r1: start proportion of the population in each SEIR class.
- window: time window to keep rt constant.
- out: vector that represents the proportion of the population that leave each city during
    the day.
- M: Matrix that has at position (i, j) how much population goes from city i to city j, the
    proportion with respect to the population of the destiny (j). It should have 0 on the
    diagonal.
- Mt: transpose of M.
"""
struct SEIR_Parameters
    # Basic epidemiological constants that define the SEIR model
    tinc::Float64
    tinf::Float64
    rep::Float64
    ndays::Int64
    ncities::Int64
    s1::Vector{Float64}
    e1::Vector{Float64}
    i1::Vector{Float64}
    r1::Vector{Float64}
    window::Int64
    out::Vector{Float64}
    M::SparseMatrixCSC{Float64,Int64}
    Mt::SparseMatrixCSC{Float64,Int64}

    """
        SEIR_Parameters(tinc, tinf, rep, ndays, s1, e1, i1, r1, window, out, M, Mt)

    SEIR parameters with mobility information (out, M, Mt).
    """
    function SEIR_Parameters(tinc, tinf, rep, ndays, s1, e1, i1, r1, window, out, M, Mt)
        ls1 = length(s1)
        @assert length(e1) == ls1
        @assert length(i1) == ls1
        @assert length(r1) == ls1
        @assert size(M) == (ls1, ls1)
        @assert all(M .>= 0.0)
        @assert size(Mt) == (ls1, ls1)
        @assert all(Mt .>= 0.0)
        @assert size(out) == (ls1,)
        @assert all(out .>= 0.0)

        new(tinc, tinf, rep, ndays, ls1, s1, e1, i1, r1, window, out, M, Mt)
    end

    """
        SEIR_Parameters(tinc, tinf, rep, ndays, s1, e1, i1, r1, window)

    SEIR parameters without mobility information, which is assumed to be 0.
    """
    function SEIR_Parameters(tinc, tinf, rep, ndays, s1, e1, i1, r1, window)
        ls1 = length(s1)
        out = zeros(ls1)
        M = spzeros(ls1, ls1)
        Mt = spzeros(ls1, ls1)
        SEIR_Parameters(tinc, tinf, rep, ndays, s1, e1, i1, r1, window, out, M, Mt)
    end

    """
        SEIR_Parameters(tinc, tinf, rep, ndays, s1, e1, i1, r1)

    SEIR parameters with unit time window and without mobility information, which is assumed 
    to be 0.
    """
    function SEIR_Parameters(tinc, tinf, rep, ndays, s1, e1, i1, r1)
        SEIR_Parameters(tinc, tinf, rep, ndays, s1, e1, i1, r1, 1)
    end
end


"""
    mapind(d, prm)

    Allows for natural use of rt while computing the right index mapping in time d.
"""
function mapind(d, prm)
    return prm.window*div(d - 1, prm.window) + 1
end


"""
    expand(rt, prm)

Expand rt to a full prm.ndays vector.
"""
function expand(rt, prm)
    full_rt = zeros(prm.ncities, prm.ndays)
    for c in 1:prm.ncities, d in 1:prm.ndays
        full_rt[c, d] = rt[c, mapind(d, prm)]
    end
    return full_rt
end


"""
    seir_model_with_free_initial_value(prm)

Build an optimization model with the SEIR discretization as constraints. The inicial
parameters are not initialized and remain free. This can be useful, for example, to fit the
initial parameters to observed data.
"""
function seir_model_with_free_initial_values(prm)
    # Save work and get col indices of both M and Mt
    coli_M = [findnz(prm.M[:,c])[1] for c in 1:prm.ncities]
    coli_Mt = [findnz(prm.Mt[:,c])[1] for c in 1:prm.ncities]

    # Create the optimization model.
    # I am reverting to mumps because I can not limit ma97 to use
    # only the actual cores in my machine and mumps seems to be doing 
    # fine.
    m = Model(optimizer_with_attributes(Ipopt.Optimizer,
        "print_level" => 5, "linear_solver" => "mumps"))
    # For simplicity I am assuming that one step per day is OK.
    dt = 1.0

    # Note that I do not fix the initial state. It should be defined elsewhere.
    # State variables
    @variable(m, 0.0 <= s[1:prm.ncities, 1:prm.ndays] <= 1.0)
    @variable(m, 0.0 <= e[1:prm.ncities, 1:prm.ndays] <= 1.0)
    @variable(m, 0.0 <= i[1:prm.ncities, 1:prm.ndays] <= 1.0)
    @variable(m, 0.0 <= r[1:prm.ncities, 1:prm.ndays] <= 1.0)

    # Control variable
    @variable(m, 0.0 <= rt[1:prm.ncities, 1:prm.window:prm.ndays] <= prm.rep)

    # Expressions that define "sub-states"

    # enter denotes the proportion of the population that enter city c during
    # the day.
    @NLexpression(m, enter[c=1:prm.ncities, t=1:prm.ndays],
        sum(prm.M[k, c]*(1.0 - i[k, t]) for k in coli_M[c])
    )
    # p_day is the ratio that the population of a city varies during the day
    @NLexpression(m, p_day[c=1:prm.ncities, t=1:prm.ndays],
        (1.0 - prm.out[c]) + prm.out[c]*i[c, t] + enter[c, t]
    )

    # Parameter that measures how much important is the infection during the day
    # when compared to the night.
    α = 2/3

    # Implement a vectorized version of Heun's method.

    # Compute the gradients at time t of the SEIR model.

    # Estimates the infection rate of the susceptible people from city c
    # that went to the other cities k.
    @NLexpression(m, t1[c=1:prm.ncities, t=1:prm.ndays],
        sum(rt[k, mapind(t, prm)]*prm.Mt[k, c]*s[c, t]*i[k, t]/p_day[k, t] for k = coli_Mt[c])
    )
    @NLexpression(m, ds[c=1:prm.ncities, t=1:prm.ndays],
        -1.0/prm.tinf*(
         α*( rt[c, mapind(t, prm)]*(1.0 - prm.out[c])*s[c, t]*i[c, t]/p_day[c, t] +
             t1[c, t] ) +
         (1 - α)*rt[c, mapind(t, prm)]*s[c, t]*i[c, mapind(t, prm)])
    )
    @NLexpression(m, de[c=1:prm.ncities, t=1:prm.ndays],
        -ds[c, t] - (1.0/prm.tinc)*e[c,t]
    )
    @NLexpression(m, di[c=1:prm.ncities, t=1:prm.ndays],
        (1.0/prm.tinc)*e[c, t] - (1.0/prm.tinf)*i[c, t]
    )
    @NLexpression(m, dr[c=1:prm.ncities, t=1:prm.ndays],
        (1.0/prm.tinf)*i[c, t]
    )

    # Do the Euler step from the point in time t - 1 computing the intermediate
    # point that we express as ?p (p is for plus).
    @NLexpression(m, sp[c=1:prm.ncities, t=2:prm.ndays], s[c, t - 1] + ds[c, t - 1]*dt)
    @NLexpression(m, ep[c=1:prm.ncities, t=2:prm.ndays], e[c, t - 1] + de[c, t - 1]*dt)
    @NLexpression(m, ip[c=1:prm.ncities, t=2:prm.ndays], i[c, t - 1] + di[c, t - 1]*dt)
    @NLexpression(m, rp[c=1:prm.ncities, t=2:prm.ndays], r[c, t - 1] + dr[c, t - 1]*dt)

    # Compute the gradients in the intermediate point.
    @NLexpression(m, t2[c=1:prm.ncities, t=2:prm.ndays],
        sum(rt[k, mapind(t, prm)]*prm.Mt[k, c]*sp[c, t]*ip[k, t]/p_day[k, t] for k = coli_Mt[c])
    )
    @NLexpression(m, dsp[c=1:prm.ncities, t=2:prm.ndays],
        -1.0/prm.tinf*(
        α*( rt[c, mapind(t, prm)]*(1.0 - prm.out[c])*sp[c, t]*ip[c, t]/p_day[c, t] +
            t2[c, t] ) +
        (1 - α)*rt[c, mapind(t, prm)]*sp[c, t]*ip[c, t])
    )
    @NLexpression(m, dep[c=1:prm.ncities, t=2:prm.ndays],
        -dsp[c, t] - (1.0/prm.tinc)*ep[c,t]
    )
    @NLexpression(m, dip[c=1:prm.ncities, t=2:prm.ndays],
        (1.0/prm.tinc)*ep[c, t] - (1.0/prm.tinf)*ip[c, t]
    )
    @NLexpression(m, drp[c=1:prm.ncities, t=2:prm.ndays],
        (1.0/prm.tinf)*ip[c, t]
    )

    # Perform a Heun's update
    @NLconstraint(m, [c=1:prm.ncities, t=2:prm.ndays],
        s[c, t] == s[c, t - 1] + 0.5*(ds[c, t - 1] + dsp[c, t])*dt
    )
    @NLconstraint(m, [c=1:prm.ncities, t=2:prm.ndays],
        e[c, t] == e[c, t - 1] + 0.5*(de[c, t - 1] + dep[c, t])*dt
    )
    @NLconstraint(m, [c=1:prm.ncities, t=2:prm.ndays],
        i[c, t] == i[c, t - 1] + 0.5*(di[c, t - 1] + dip[c, t])*dt
    )
    @NLconstraint(m, [c=1:prm.ncities, t=2:prm.ndays],
        r[c, t] == r[c, t - 1] + 0.5*(dr[c, t - 1] + drp[c, t])*dt
    )

    return m
end


"""
    seir_model(prm)

Creates a SEIR model setting the initial parameters for the SEIR variables from prm.
"""
function seir_model(prm)
    m = seir_model_with_free_initial_values(prm)

    # Initial state
    s1, e1, i1, r1 = m[:s][:, 1], m[:e][:, 1], m[:i][:, 1], m[:r][:, 1]
    for c in 1:prm.ncities
        fix(s1[c], prm.s1[c]; force=true)
        fix(e1[c], prm.e1[c]; force=true)
        fix(i1[c], prm.i1[c]; force=true)
        fix(r1[c], prm.r1[c]; force=true)
    end
    return m
end


"""
    fixed_rt_model(prm)

Creates a model from prm setting all initial parameters and defining the RT as the natural
R0 set in prm.
"""
function fixed_rt_model(prm)
    m = seir_model(prm)
    rt = m[:rt]

    # Fix all rts
    for c = 1:prm.ncities
        for t = 1:prm.window:prm.ndays
            fix(rt[c, t], prm.rep; force=true)
        end
    end
    return m
end


"""
    fit_initcond_model(prm, initial_data)

Fit the initial parameters for a single city using squared absolute error from initial_data.
"""
function fit_initial(tinc, tinf, rep, data)

    prm = SEIR_Parameters(tinc, tinf, rep, length(data), [0.0], [0.0], [0.0], [0.0], 
        1, [0.0], zeros(1, 1), zeros(1, 1))

    m = seir_model_with_free_initial_values(prm)

    # Initial state
    s1, e1, i, r1, rt = m[:s][1, 1], m[:e][1, 1], m[:i], m[:r][1, 1], m[:rt]
    fix(r1, prm.r1[1]; force=true)
    set_start_value(s1, prm.s1[1])
    set_start_value(e1, prm.e1[1])
    set_start_value(i[1, 1], prm.i1[1])
    for t = 1:prm.window:prm.ndays
        fix(rt[1, t], prm.rep; force=true)
    end

    @constraint(m, s1 + e1 + i[1, 1] + r1 == 1.0)
    # Compute a scaling factor so as a least square objective makes more sense
    factor = 1.0/mean(data)
    @objective(m, Min, sum((factor*(i[t] - data[t]))^2 for t = 1:prm.ndays))

    optimize!(m)

    return value(s1), value(e1), value(i[1, 1]), value(r1)
end


"""
    control_multcities

Built a simple control problem that tries to force the infected to remain below target every
day for every city using daily controls with small total variation.

# Attributes

- prm: SEIR parameters with initial state and other informations.
- population: population of each city.
- target: limit of infected to impose at each city for each day.
- force_difference: allow to turn off the alternation for a city in certain days. Should be
    used if alternation happens even after the eipdemy is dieing off.
- hammer_durarion: Duration in days of a intial hammer phase.
- hammer: Rt level that should be achieved during hammer phase.
- min_rt: minimum rt achievable outside the hammer phases.
"""
function control_multcities(prm, population, target, force_difference, hammer_duration=0,
    hammer=0.89, min_rt=1.0)
    @assert mod(hammer_duration, prm.window) == 0

    m = seir_model(prm)

    # Fix rt during hammer phase
    rt = m[:rt]
    for c = 1:prm.ncities, d = 1:prm.window:hammer_duration
        fix(rt[c, d], hammer; force=true)
    end

    # Set the minimum rt achievable after the hammer phase.
    for c = 1:prm.ncities, d = hammer_duration + 1:prm.window:prm.ndays
        set_lower_bound(rt[c, d], min_rt)
    end

    # Compute the total variation of the control rt
    rt = m[:rt]
    @variable(m, tot_var[c=1:prm.ncities, t=hammer_duration + prm.window + 1:prm.window:prm.ndays])
    @constraint(m, tot_var1[c=1:prm.ncities, t=hammer_duration + prm.window + 1:prm.window:prm.ndays],
        rt[c, t - prm.window] - rt[c, t] <= tot_var[c, t]
    )
    @constraint(m, tot_var2[c=1:prm.ncities, t=hammer_duration + 2:prm.ndays],
        rt[c, t] - rt[c, t - prm.window] <= tot_var[c, t]
    )

    # Constraint on maximum level of infection
    i = m[:i]
    @constraint(m, [c=1:prm.ncities, t=hammer_duration + 1:prm.ndays], 
        i[c, t] <= target[c, t]
    )

    # Compute the weights for the objectives terms
    effect_pop = sqrt.(population)
    mean_population = mean(effect_pop)
    dif_matrix = Matrix{Float64}(undef, prm.ncities, prm.ndays)
    for c = 1:prm.ncities, d = 1:prm.ndays
        dif_matrix[c, d] = force_difference[c, d] / mean_population / (2*prm.ncities)
    end
    # Define objective
    @objective(m, Min,
        # Try to keep life as normal as possible
        sum(effect_pop[c]/mean_population*(prm.rep - rt[c, d])
            for c = 1:prm.ncities for d = hammer_duration + 1:prm.window:prm.ndays) +
        # Avoid large variations
        sum(tot_var) -
        # Try to enforce different cities to alternate the controls
        10.0/(prm.rep^2)*sum(
            minimum((effect_pop[c], effect_pop[cl]))*
            minimum((dif_matrix[c, d], dif_matrix[cl, d]))*
            (rt[c, d] - rt[cl, d])^2
            for c = 1:prm.ncities 
            for cl = c + 1:prm.ncities 
            for d = hammer_duration + 1:prm.window:prm.ndays
        )
    )

    return m
end


"""
    window_control_multcities

Built a simple control problem that tries to force the infected to remain below target every
day for every city using daily controls but only allow them to change in the start of the
time windows.

# Attributes

- prm: SEIR parameters with initial state and other informations.
- population: population of each city.
- target: limit of infected to impose at each city for each day.
- window: number of days for the time window.
- force_difference: allow to turn off the alternation for a city in certain days. Should be
    used if alternation happens even after the eipdemy is dieing off.
- hammer_durarion: Duration in days of a intial hammer phase.
- hammer: Rt level that should be achieved during hammer phase.
- min_rt: minimum rt achievable outside the hammer phases.
"""
function window_control_multcities(prm, population, target, force_difference, 
    hammer_duration=0, hammer=0.89, min_rt=1.0)
    @assert mod(hammer_duration, prm.window) == 0

    m = seir_model(prm)

    # Fix rt during hammer phase
    rt = m[:rt]
    for c = 1:prm.ncities, d = 1:prm.window:hammer_duration
        fix(rt[c, d], hammer; force=true)
    end

    # Set the minimum rt achievable after the hammer phase.
    for c = 1:prm.ncities, d = hammer_duration + 1:prm.window:prm.ndays
        set_lower_bound(rt[c, d], min_rt)
    end

    # Bound the maximal infection rate
    i = m[:i]
    @constraint(m, [c=1:prm.ncities, t=hammer_duration + 1:prm.ndays], 
        i[c, t] <= target[c, t]
    )

    # Compute the weights for the objectives terms
    effect_pop = sqrt.(population)
    mean_population = mean(effect_pop)
    dif_matrix = Matrix{Float64}(undef, prm.ncities, prm.ndays)
    for c = 1:prm.ncities, d = 1:prm.ndays
        dif_matrix[c, d] = force_difference[c, d] / mean_population / (2*prm.ncities)
    end
    # Define objective
    @objective(m, Min,
        # Try to keep as many people working as possible
        prm.window*sum(effect_pop[c]/mean_population*(prm.rep - rt[c, d])
            for c = 1:prm.ncities for d = hammer_duration+1:prm.window:prm.ndays) -
        # Try to alternate with a single city.
        prm.window/(prm.rep^2)*sum(
            force_difference[c, d]*(rt[c, d] - rt[c, d - prm.window])^2 
            for c = 1:prm.ncities 
            for d = hammer_duration + prm.window + 1:prm.window:prm.ndays
        ) -
        # Try to enforce different cities to alternate the controls
        10.0*prm.window/(prm.rep^2)*sum(
            minimum((effect_pop[c], effect_pop[cl]))*
            minimum((dif_matrix[c, d], dif_matrix[cl, d]))*
            (rt[c, d] - rt[cl, d])^2
            for c = 1:prm.ncities 
            for cl = c + 1:prm.ncities 
            for d = hammer_duration + 1:prm.window:prm.ndays
        )
    )

    return m
end


"""
    simulate_control

Simulate the SEIR mdel with a given control checking whether the target is achieved.

TODO: fix this, hammer_duration does not even exist.

"""
function simulate_control(prm, population, control, target)
    @assert mod(hammer_duration, prm.window) == 0

    m = seir_model(prm)

    rt = m[:rt]
    for c=1:prm.ncities, d=1:prm.ndays
        fix(rt[c, mapind(d, prm)], control[c, d]; force=true)
    end

    # Constraint on maximum level of infection
    i = m[:i]
    @constraint(m, [c=1:prm.ncities, t=2:prm.ndays], i[c, t] <= target)

    # Compute the weights for the objectives terms
    effect_pop = sqrt.(population)
    mean_population = mean(effect_pop)
    dif_matrix = Matrix{Float64}(undef, prm.ncities, prm.ndays)
    for c = 1:prm.ncities, d = 1:prm.ndays
        dif_matrix[c, d] = force_difference[c, d] / mean_population / (2*prm.ncities)
    end
    # Define objective
    @objective(m, Min,
        # Try to keep as many people working as possible
        sum(prm.window*effect_pop[c]/mean_population*(prm.rep - rt[c, d])
            for c = 1:prm.ncities for d = hammer_duration+1:prm.window:prm.ndays) -
        # Try to enforce different cities to alternate the controls
        100.0/(prm.rep^2)*sum(
            minimum((effect_pop[c], effect_pop[cl]))*
            minimum((dif_matrix[c, d], dif_matrix[cl, d]))*
            (rt[c, d] - rt[cl, d]^2)
            for c = 1:prm.ncities 
            for cl = c + 1:prm.ncities 
            for d = hammer_duration + 1:prm.window:prm.ndays
            )
    )

    return m
end


"""
    playground

Funtion to test ideas.
"""

function playground(prm, population, target, final_target, hammer_durarion)
    @assert mod(hammer_duration, prm.window) == 0

    m = seir_model(prm)

    # Constraint the overall number of infected to simulate a full health pool.
    i = m[:i]
    @constraint(m, sum(population[c]*i[c,prm.ndays] for c = 1:prm.ncities) <= final_target)

    # Bound the maximal infection rate
    @constraint(m, [c=1:prm.ncities, t=hammer_duration + 1:prm.ndays],
        i[c, t] <= target[c, t]
    )

    # Find the maximal acceptable Rt
    @variable(m, min_rt)
    rt = m[:rt]
    @constraint(m, bound_rt[c = 1:prm.ncities, d = 1:prm.window:prm.ndays], min_rt <= rt[c, d])
    @objective(m, Max, min_rt)

    return m
end
