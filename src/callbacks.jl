# Use Recursion to find the first callback for type-stability

# Base Case: Only one callback
function find_first_continuous_callback(integrator, callback::AbstractContinuousCallback)
  (find_callback_time(integrator,callback,1)...,1,1)
end

# Starting Case: Compute on the first callback
function find_first_continuous_callback(integrator, callback::AbstractContinuousCallback, args...)
  find_first_continuous_callback(integrator,find_callback_time(integrator,callback,1)...,1,1,args...)
end

function find_first_continuous_callback(integrator,tmin::Number,upcrossing::Float64,
                                        event_occured::Bool,idx::Int,counter::Int,
                                        callback2)
  counter += 1 # counter is idx for callback2.
  tmin2,upcrossing2,event_occurred2 = find_callback_time(integrator,callback2,counter)

  if event_occurred2 && (tmin2 < tmin || !event_occured)
    return tmin2,upcrossing2,true,counter,counter
  else
    return tmin,upcrossing,event_occured,idx,counter
  end
end

function find_first_continuous_callback(integrator,tmin::Number,upcrossing::Float64,event_occured::Bool,idx::Int,counter::Int,callback2,args...)
  find_first_continuous_callback(integrator,find_first_continuous_callback(integrator,tmin,upcrossing,event_occured,idx,counter,callback2)...,args...)
end

@inline function determine_event_occurance(integrator,callback,counter)
  event_occurred = false
  Θs = range(typeof(integrator.t)(0), stop=typeof(integrator.t)(1), length=callback.interp_points)
  interp_index = 0
  # Check if the event occured
  if typeof(callback.idxs) <: Nothing
    previous_condition = callback.condition(integrator.uprev,integrator.tprev,integrator)
  elseif typeof(callback.idxs) <: Number
    previous_condition = callback.condition(integrator.uprev[callback.idxs],integrator.tprev,integrator)
  else
    previous_condition = callback.condition(@view(integrator.uprev[callback.idxs]),integrator.tprev,integrator)
  end

  if integrator.event_last_time == counter && abs(previous_condition) < 100callback.abstol

    # abs(previous_condition) < callback.abstol is for multiple events: only
    # condition this on the correct event

    # If there was a previous event, utilize the derivative at the start to
    # chose the previous sign. If the derivative is positive at tprev, then
    # we treat the value as positive, and derivative is negative then we
    # treat the value as negative, reguardless of the postiivity/negativity
    # of the true value due to it being =0 sans floating point issues.

    if typeof(integrator.cache) <: StochasticDiffEqMutableCache
      if typeof(callback.idxs) <: Nothing
        tmp = integrator.cache.tmp
      else !(typeof(callback.idxs) <: Number)
        tmp = @view integrator.cache.tmp[callback.idxs]
      end
    end

    if typeof(integrator.cache) <: StochasticDiffEqMutableCache && !(typeof(callback.idxs) <: Number)
      sde_interpolant!(tmp,100eps(integrator.tprev),
                       integrator,callback.idxs,Val{0})
    else

      tmp = sde_interpolant(100eps(integrator.tprev),
                            integrator,callback.idxs,Val{0})
    end

    tmp_condition = callback.condition(tmp,integrator.tprev +
                                       100eps(typeof(integrator.tprev)),
                                       integrator)

    prev_sign = sign((tmp_condition-previous_condition)/integrator.dt)
  else
    prev_sign = sign(previous_condition)
  end

  prev_sign_index = 1
  if typeof(callback.idxs) <: Nothing
    next_sign = sign(callback.condition(integrator.u,integrator.t,integrator))
  elseif typeof(callback.idxs) <: Number
    next_sign = sign(callback.condition(integrator.u[callback.idxs],integrator.t,integrator))
  else
    next_sign = sign(callback.condition(@view(integrator.u[callback.idxs]),integrator.t,integrator))
  end
  if ((prev_sign<0 && !(typeof(callback.affect!)<:Nothing)) || (prev_sign>0 && !(typeof(callback.affect_neg!)<:Nothing))) && prev_sign*next_sign<=0
    event_occurred = true
    interp_index = callback.interp_points
  elseif callback.interp_points!=0 # Use the interpolants for safety checking
    if typeof(integrator.cache) <: StochasticDiffEqMutableCache
      if typeof(callback.idxs) <: Nothing
        tmp = integrator.cache.tmp
      elseif !(typeof(callback.idxs) <: Number)
        tmp = @view integrator.cache.tmp[callback.idxs]
      end
    end
    for i in 2:length(Θs)
      if typeof(integrator.cache) <: StochasticDiffEqMutableCache && !(typeof(callback.idxs) <: Number)
        sde_interpolant!(tmp,Θs[i],integrator,callback.idxs,Val{0})
      else
        tmp = sde_interpolant(Θs[i],integrator,callback.idxs,Val{0})
      end
      new_sign = callback.condition(tmp,integrator.tprev+integrator.dt*Θs[i],integrator)
      if prev_sign == 0
        prev_sign = sign(new_sign)
        prev_sign_index = i
      end
      if ((prev_sign<0 && !(typeof(callback.affect!)<:Nothing)) || (prev_sign>0 && !(typeof(callback.affect_neg!)<:Nothing))) && prev_sign*new_sign<0
        event_occurred = true
        interp_index = i
        break
      end
    end
  end
  event_occurred,interp_index,Θs,prev_sign,prev_sign_index
end

function find_callback_time(integrator,callback,counter)
  event_occurred,interp_index,Θs,prev_sign,prev_sign_index = determine_event_occurance(integrator,callback,counter)
  if event_occurred
    if typeof(callback.condition) <: Nothing
      new_t = zero(typeof(integrator.t))
    else
      if callback.interp_points!=0
        top_Θ = Θs[interp_index] # Top at the smallest
        bottom_θ = Θs[prev_sign_index]
      else
        top_Θ = typeof(integrator.t)(1)
        bottom_θ = typeof(integrator.t)(0)
      end
      if callback.rootfind
        if typeof(integrator.cache) <: StochasticDiffEqMutableCache
          if typeof(callback.idxs) <: Nothing
            tmp = integrator.cache.tmp
          elseif !(typeof(callback.idxs) <: Number)
            tmp = @view integrator.cache.tmp[callback.idxs]
          end
        end
        zero_func = (Θ) -> begin
          if typeof(integrator.cache) <: StochasticDiffEqMutableCache && !(typeof(callback.idxs) <: Number)
            sde_interpolant!(tmp,Θ,integrator,callback.idxs,Val{0})
          else
            tmp = sde_interpolant(Θ,integrator,callback.idxs,Val{0})
          end
          callback.condition(tmp,integrator.tprev+Θ*integrator.dt,integrator)
        end

        if zero_func(top_Θ) == 0
          Θ = top_Θ
        else
          Θ = prevfloat(find_zero(zero_func,(bottom_θ,top_Θ),Roots.AlefeldPotraShi(),atol = callback.abstol/10))
          if integrator.event_last_time == counter &&
             abs(zero_func(bottom_θ)) < 100callback.abstol &&
             prev_sign_index == 1
             # Determined that there is an event by derivative
             # But floating point error may make the end point negative
             sign_top = sign(zero_func(top_Θ))
             bottom_θ += 2eps(typeof(bottom_θ))
             iter = 1
             while sign(zero_func(bottom_θ)) == sign_top && iter < 12
               bottom_θ *= 5
               iter += 1
             end
             iter == 12 && error("Double callback crossing floating pointer reducer errored. Report this issue.")
          end
          Θ = prevfloat(find_zero(zero_func,(bottom_θ,top_Θ),Roots.AlefeldPotraShi(),atol = callback.abstol/100))
        end

        #Θ = prevfloat(...)
        # prevfloat guerentees that the new time is either 1 floating point
        # numbers just before the event or directly at zero, but not after.
        # If there's a barrier which is never supposed to be crossed,
        # then this will ensure that
        # The item never leaves the domain. Otherwise Roots.jl can return
        # a float which is slightly after, making it out of the domain, causing
        # havoc.
        new_t = integrator.dt*Θ
      elseif interp_index != callback.interp_points
        new_t = integrator.dt*Θs[interp_index]
      else
        # If no solve and no interpolants, just use endpoint
        new_t = integrator.dt
      end
    end
  else
    new_t = zero(typeof(integrator.t))
  end
  new_t,prev_sign,event_occurred
end

function apply_callback!(integrator,callback::ContinuousCallback,cb_time,prev_sign)
  saved_in_cb = false
  if cb_time != zero(typeof(integrator.t))
    change_t_via_interpolation!(integrator,integrator.tprev+cb_time)
  end

  # handle saveat
  _, saved_in_saveat = savevalues!(integrator)

  if callback.save_positions[1]
    # if already saved then skip saving
    saved_in_saveat || savevalues!(integrator,true)
    saved_in_cb = true
  end

  integrator.u_modified = true

  if prev_sign < 0
    if typeof(callback.affect!) <: Nothing
      integrator.u_modified = false
    else
      callback.affect!(integrator)
    end
  elseif prev_sign > 0
    if typeof(callback.affect_neg!) <: Nothing
      integrator.u_modified = false
    else
      callback.affect_neg!(integrator)
    end
  end

  if integrator.u_modified
    #reeval_internals_due_to_modification!(integrator)
    if callback.save_positions[2]
      savevalues!(integrator,true)
      saved_in_cb = true
    end
    return true,saved_in_cb
  end
  false,saved_in_cb
end

#Base Case: Just one
function apply_discrete_callback!(integrator::SDEIntegrator,callback::DiscreteCallback)
  saved_in_cb = false
  if callback.condition(integrator.u,integrator.t,integrator)
    # handle saveat
    _, saved_in_saveat = savevalues!(integrator)
    if callback.save_positions[1]
      # if already saved then skip saving
      saved_in_saveat || savevalues!(integrator,true)
      saved_in_cb = true
    end
    integrator.u_modified = true
    callback.affect!(integrator)
    if callback.save_positions[2]
      savevalues!(integrator,true)
      saved_in_cb = true
    end
  end
  integrator.u_modified,saved_in_cb
end

#Starting: Get bool from first and do next
function apply_discrete_callback!(integrator::SDEIntegrator,callback::DiscreteCallback,args...)
  apply_discrete_callback!(integrator,apply_discrete_callback!(integrator,callback)...,args...)
end

function apply_discrete_callback!(integrator::SDEIntegrator,discrete_modified::Bool,saved_in_cb::Bool,callback::DiscreteCallback,args...)
  bool,saved_in_cb2 = apply_discrete_callback!(integrator,apply_discrete_callback!(integrator,callback)...,args...)
  discrete_modified || bool, saved_in_cb || saved_in_cb2
end

function apply_discrete_callback!(integrator::SDEIntegrator,discrete_modified::Bool,saved_in_cb::Bool,callback::DiscreteCallback)
  bool,saved_in_cb2 = apply_discrete_callback!(integrator,callback)
  discrete_modified || bool, saved_in_cb || saved_in_cb2
end
