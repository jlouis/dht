%%% @doc Module dht_par runs commands in parallel for the DHT
%%% @end
%%% @private
-module(dht_par).

-export([pmap/2, partition/1]).

%% @doc Very very parallel pmap implementation :)
%% @end
%% @todo: fix this parallelism
-spec pmap(fun((A) -> B), [A]) -> [B].
pmap(F, Es) ->
    Parent = self(),
    Running = [spawn_monitor(fun() -> Parent ! {self(),  F(E)} end) || E <- Es],
    collect(Running, 5000).
    
collect([], _Timeout) -> [];
collect([{Pid, MRef} | Next], Timeout) ->
    receive
        {Pid, Res} ->
           erlang:demonitor(MRef, [flush]),
           [{ok, Res} | collect(Next, Timeout)];
        {'DOWN', MRef, process, Pid, Reason} ->
           [{error, Reason} | collect(Next, Timeout)]
    after Timeout ->
        exit(pmap_timeout)
    end.
    
partition(Res) -> partition(Res, [], []).

partition([], OK, Err) -> {lists:reverse(OK), lists:reverse(Err)};
partition([{ok, R} | Next], OK, Err) -> partition(Next, [R | OK], Err);
partition([{error, E} | Next], OK, Err) -> partition(Next, OK, [E | Err]).
