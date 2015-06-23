-module(dht_time_eqc).
-compile(export_all).

-include_lib("eqc/include/eqc.hrl").
-include_lib("eqc/include/eqc_component.hrl").

-type time() :: integer().
-type time_ref() :: integer().

-record(state, {
	time = 0 :: time(),
	timers = [] :: [{time(), {time_ref(), term(), term()}}],
	time_ref = 0 :: time_ref()
}).

api_spec() ->
    #api_spec {
      language = erlang,
      modules = [ ]
    }.
    
gen_initial_state() ->
    #state { time = int() }.

initial_state() -> #state{}.

%% ADVANCING TIME
%% ------------------------------------

advance_time(_Advance) -> ok.
advance_time_args(_S) ->
    T = oneof([
        ?LET(K, nat(), K+1),
        ?LET({K, N}, {nat(), nat()}, (N+1)*1000 + K),
        ?LET({K, N, M}, {nat(), nat(), nat()}, (M+1)*60*1000 + N*1000 + K)
    ]),
    [T].

%% TRIGGERING OF TIMERS
%% ------------------------------------
can_fire(#state { time = T, timers = TS }) ->
     [X || X = {TP, _, _, _} <- TS, T >= TP].
   
trigger_pre(S, []) -> can_fire(S) /= [].
    
trigger_return(S, []) ->
    case lists:keysort(1, can_fire(S)) of
        [{_TP, TRef, Pid, Msg} | _] -> {timeout, TRef, Pid, Msg}
    end.
    
trigger_next(#state { timers = TS } = S, _, []) ->
    case lists:keysort(1, can_fire(S)) of
        [{_, TRef, _, _} | _] -> S#state{ timers = lists:keydelete(2, TRef, TS) }
    end.
    
%% Advancing time transitions the system into a state where the time is incremented
%% by A.
advance_time_next(#state { time = T } = State, _, [A]) -> State#state { time = T+A }.
advance_time_return(_S, [_]) -> ok.

%% INTERNAL CALLS IN THE MODEL
%% -------------------------------------------

monotonic_time_callers() -> [dht_routing_meta_eqc, dht_routing_table_eqc, dht_state_eqc].
monotonic_time_return(#state { time = T }, []) -> T.

convert_time_unit_return() -> [dht_routing_meta_eqc, dht_routing_table_eqc, dht_state_eqc].
convert_time_unit_return(_S, [T, native, milli_seconds]) -> T;
convert_time_unit_return(_S, [T, milli_seconds, native]) -> T.

send_after_return(#state { time_ref = Ref }, [_Timeout, _Pid, _Msg]) -> {tref, Ref}.

send_after_next(#state { time = T, time_ref = Ref, timers = TS } = S, _, [Timeout, Pid, Msg]) ->
    TriggerPoint = T + Timeout,
    S#state { time_ref = Ref + 1, timers = TS ++ [{TriggerPoint, Ref, Pid, Msg}] }.

cancel_timer_callers() -> [dht_routing_meta_eqc].

cancel_timer_return(#state { time = T, timers = TS }, [{tref, TRef}]) ->
    case lists:keyfind(TRef, 2, TS) of
        false -> false;
        {TriggerPoint, TRef, _Pid, _Msg} -> monus(TriggerPoint, T)
    end.

cancel_timer_next(#state { timers = TS } = S, _, [{tref, TRef}]) ->
    S#state { timers = lists:keydelete(TRef, 2, TS) }.

%% HELPER ROUTINES
%% ----------------------------------------

%% A monus operation is a subtraction for natural numbers
monus(A, B) when A > B -> A - B;
monus(A, B) when A =< B -> 0.

%% PROPERTY
%% ----------------------------------

%% The property here is a pretty dummy property as we don't need a whole lot for this to work.

%% Use a common postcondition for all commands, so we can utilize the valid return
%% of each command.
postcondition_common(S, Call, Res) ->
    eq(Res, return_value(S, Call)).

%% Main property, just verify that the commands are in sync with reality.
prop_component_correct() ->
    ?SETUP(fun() ->
        eqc_mocking:start_mocking(api_spec()),
        fun() -> ok end
    end,
    ?FORALL(St, gen_initial_state(),
    ?FORALL(Cmds, commands(?MODULE, St),
      begin
        {H,S,R} = run_commands(?MODULE, Cmds),
        pretty_commands(?MODULE, Cmds, {H,S,R},
            aggregate(with_title('Commands'), command_names(Cmds),
            collect(eqc_lib:summary('Length'), length(Cmds),
            aggregate(with_title('Features'), eqc_statem:call_features(H),
            features(eqc_statem:call_features(H),
                R == ok)))))
      end))).

%% Helper for showing states of the output:
t() -> t(5).

t(Secs) ->
    eqc:quickcheck(eqc:testing_time(Secs, eqc_statem:show_states(prop_component_correct()))).