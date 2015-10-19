-module(dht_par_eqc).

-compile(export_all).

-include_lib("eqc/include/eqc.hrl").
-include_lib("eqc/include/eqc_statem.hrl").
-include_lib("pulse/include/pulse.hrl").

initial_state() -> {}.

%% The parameter generator
gen() ->
    int().

pmap(F, Params) ->
    dht_par:pmap(F, Params).

crasher() ->
   ?LET(F, function1(int()),
     fun
       (0) -> exit(err);
       (X) -> F(X)
     end).

pmap_args(_S) ->
    [crasher(),
     list( frequency([ {10, 0}, {100, int()} ]) )].
    
pmap_return(_S, [F, Xs]) ->
    [case X of
         0 -> {error, err};
         N -> {ok, F(N)}
     end || X <- Xs].
    
postcondition_common(S, Call, Res) ->
    eq(Res, return_value(S, Call)).

prop_component_correct() ->
    ?FORALL(Cmds, commands(?MODULE),
      ?PULSE(HSR = {_,_,R}, run_commands(?MODULE, Cmds),
        begin
          pretty_commands(?MODULE, Cmds, HSR, R == ok)
        end)).

pulse_instrument() ->
  [ pulse_instrument(File) || File <- filelib:wildcard("../src/dht_par.erl") ++ filelib:wildcard("../test/dht_par_eqc.erl") ],
  ok.

pulse_instrument(File) ->
    io:format("Compiling: ~p~n", [File]),
    {ok, Mod} = compile:file(File, [{d, 'PULSE', true}, {parse_transform, pulse_instrument}]),
  code:purge(Mod),
  {module, Mod} = code:load_file(Mod),
  Mod.
