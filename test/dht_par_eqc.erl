-module(dht_par_eqc).

-compile(export_all).

-include_lib("eqc/include/eqc.hrl").
-include_lib("pulse/include/pulse.hrl").


pmap(F, Params) ->
    dht_par:pmap(F, Params).

crasher() ->
   ?LET(F, function1(int()),
     fun
       (0) -> exit(err);
       (X) -> F(X)
     end).

expected_result(F, Xs) ->
    [case X of
         0 -> {error, err};
         N -> {ok, F(N)}
     end || X <- Xs].

prop_pmap() ->
    ?FORALL([F, Xs], [crasher(), list( frequency([ {10,0}, {100, int()} ]) ) ],
      ?PULSE(Result, dht_par:pmap(F, Xs),
        begin
            Expected = expected_result(F, Xs),
            equals(Result, Expected)
        end).

pulse_instrument() ->
  [ pulse_instrument(File) || File <- filelib:wildcard("../src/dht_par.erl") ++ filelib:wildcard("../test/dht_par_eqc.erl") ],
  ok.

pulse_instrument(File) ->
    io:format("Compiling: ~p~n", [File]),
    {ok, Mod} = compile:file(File, [{d, 'PULSE', true}, {parse_transform, pulse_instrument}]),
  code:purge(Mod),
  {module, Mod} = code:load_file(Mod),
  Mod.
