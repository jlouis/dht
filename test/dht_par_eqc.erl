-module(dht_par_eqc).

-compile(export_all).

-include_lib("eqc/include/eqc.hrl").
-include_lib("pulse/include/pulse.hrl").


pmap(F, Params) ->
    dht_par:pmap(F, Params).

crasher() ->
   ?LET(F, function1(int()),
     fun
       (-1) -> timer:sleep(6000); %% Fail by timing out
       (0) -> exit(err); %% Fail by crashing
       (X) -> F(X) %% Run normally
     end).

expected_result(F, Xs) ->
    case [X || X <- Xs, X == -1] of
        [] -> [case X of 0 -> {error, err}; N -> {ok, F(N)} end || X <- Xs];
        [_|_] ->
            {'EXIT', pmap_timeout}
    end.

prop_pmap() ->
    ?FORALL([F, Xs], [crasher(), list( frequency([ {10,0}, {1, -1}, {1000, nat()} ]) ) ],
      ?PULSE(Result, (catch dht_par:pmap(F, Xs)),
        begin
            Expected = expected_result(F, Xs),
            equals(Result, Expected)
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
