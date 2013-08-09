%% @author Jesper Louis Andersen <jesper.louis.andersen@gmail.com>
%% @doc Various miscellaneous utilities not fitting into other places
%% @end
-module(etorrent_utils).

%% API

%% "stdlib-like" functions
-export([gsplit/2, queue_remove/2, group/1,
	 list_shuffle/1, date_str/1, any_to_list/1,
     merge_proplists/2, compare_proplists/2,
     find/2, wait/1, expect/1, shutdown/1, ping/1,
     first/0, group/2]).

%% crypto function
-export([init_random_generator/0, sha/1]).

%% "mock-like" functions
-export([reply/1]).

%% "time-like" functions
-export([now_subtract_seconds/2]).

%% "bittorrent-like" functions
-export([decode_ips/1, decode_ips_v6/1, base32_binary_to_integer/1]).

%% "registry-like" functions
-export([register/1,
         register_member/1,
         unregister/1,
         unregister_member/1,
         lookup/1,
         lookup_members/1,
         await/1,
         await/2]).

-export([format_address/1]).

%%====================================================================

%% @doc Graceful split.
%% Works like lists:split, but if N is greater than length(L1), then
%% it will return L1 =:= L2 and L3 = []. This will gracefully make it
%% ignore out-of-items situations.
%% @end
-spec gsplit(integer(), [term()]) -> {[term()], [term()]}.
gsplit(N, L) ->
    gsplit(N, L, []).

gsplit(_N, [], Rest) ->
    {lists:reverse(Rest), []};
gsplit(0, L1, Rest) ->
    {lists:reverse(Rest), L1};
gsplit(N, [H|T], Rest) ->
    gsplit(N-1, T, [H | Rest]).

%% @doc Remove first occurence of Item in queue() if present.
%%   Note: This function assumes the representation of queue is opaque
%%   and thus the function is quite ineffective. We can build a much
%%   much faster version if we create our own queues.
%% @end
-spec queue_remove(term(), queue()) -> queue().
queue_remove(Item, Q) ->
    QList = queue:to_list(Q),
    List = lists:delete(Item, QList),
    queue:from_list(List).

%% @doc Permute List1 randomly. Returns the permuted list.
%%  This functions usage hinges on a seeding of the RNG in Random!
%% @end
-spec list_shuffle([A]) -> [A].
list_shuffle(List) ->
    Randomized = lists:keysort(1, [{random:uniform(), Item} || Item <- List]),
    [Value || {_, Value} <- Randomized].

%% @doc A Date formatter for {{Y, Mo, D}, {H, Mi, S}}.
%% @end
-spec date_str({{integer(), integer(), integer()},
                {integer(), integer(), integer()}}) -> string().
date_str({{Y, Mo, D}, {H, Mi, S}}) ->
    lists:flatten(io_lib:format("~w-~2.2.0w-~2.2.0w ~2.2.0w:"
                                "~2.2.0w:~2.2.0w",
                                [Y,Mo,D,H,Mi,S])).

%% @doc Decode the IP response from the tracker
%% @end
-spec decode_ips(binary()) -> [{etorrent_types:ipaddr(), etorrent_types:portnum()}].
decode_ips(D) ->
    decode_ips(D, []).

decode_ips([], Accum) ->
    Accum;
decode_ips([IPDict | Rest], Accum) ->
    IP = etorrent_bcoding:get_value("ip", IPDict),
    Port = etorrent_bcoding:get_value("port", IPDict),
    decode_ips(Rest, [{binary_to_list(IP), Port} | Accum]);
decode_ips(<<>>, Accum) ->
    Accum;
decode_ips(<<B1:8, B2:8, B3:8, B4:8, Port:16/big, Rest/binary>>, Accum) ->
    decode_ips(Rest, [{{B1, B2, B3, B4}, Port} | Accum]);
decode_ips(_Odd, Accum) ->
    Accum. % This case is to handle wrong tracker returns. Ignore spurious bytes.

decode_ips_v6(<<>>) -> [];
decode_ips_v6(<<B1:16/big, B2:16/big, B3:16/big,
                B4:16/big, B5:16/big, B6:16/big, B7:16/big, B8:16/big,
                Port:16/big, Rest/binary>>) ->
    [{{B1, B2, B3, B4, B5, B6, B7, B8}, Port} | decode_ips_v6(Rest)].

%% @doc Group a sorted list
%%  if the input is a sorted list L, the output is [{E, C}] where E is an element
%%  occurring in L and C is a number stating how many times E occurred.
%% @end
group([]) -> [];
group([E | L]) ->
    group(E, 1, L).

group(E, K, []) -> [{E, K}];
group(E, K, [E | R]) -> group(E, K+1, R);
group(E, K, [F | R]) -> [{E, K} | group(F, 1, R)].

%% @doc Group a list of values using a key function.
%% This function will return a list of key-value pairs where
%% the key is returned by the key function and the value is
%% a list of values having that key.
%% The function must return a {Key, Value} pair.
%% @end
-spec group(fun((term()) -> {term(), term()}), []) -> [{term(), []}].
group(Function, List) ->
    groupby(Function, List, gb_trees:empty()).

groupby(_Function, [], Acc) ->
    gb_trees:to_list(Acc);

groupby(Function, [H|T], Acc) ->
    {Key, Value} = Function(H),
    TmpAcc = case gb_trees:is_defined(Key, Acc) of
        true  -> Acc;
        false -> gb_trees:insert(Key, [], Acc)
    end,
    Values = gb_trees:get(Key, TmpAcc),
    NewAcc = gb_trees:update(Key, [Value|Values], TmpAcc),
    groupby(Function, T, NewAcc).


% @doc Subtract a time delta in millsecs from a now() triple
% @end
-spec now_subtract_seconds({integer(), integer(), integer()}, integer()) ->
    {integer(), integer(), integer()}.
now_subtract_seconds({Megasecs, Secs, Ms}, Subsecs) ->
    case Secs - Subsecs of
        N when N >= 0 ->
            {Megasecs, N, Ms};
        N ->
            Needed = abs(N) div 1000000 + 1,
            {Megasecs - Needed, N + (Needed * 1000000), Ms}
    end.

any_to_list(V) when is_list(V) ->
    V;
any_to_list(V) when is_integer(V) ->
    integer_to_list(V);
any_to_list(V) when is_atom(V) ->
    atom_to_list(V);
any_to_list(V) when is_binary(V) ->
    binary_to_list(V).


%% @doc Returns a proplist formed by merging OldProp and NewProp. If a key
%%      presents only in OldProp or NewProp, the tuple is picked. If a key
%%      presents in both OldProp and NewProp, the tuple from NewProp is
%%      picked.
%% @end
-spec merge_proplists(proplists:proplist(), proplists:proplist()) ->
    proplists:proplist().
merge_proplists(OldProp, NewProp) ->
    lists:ukeymerge(1, lists:ukeysort(1, NewProp), lists:ukeysort(1, OldProp)).

%% @doc Returns true if two proplists match regardless of the order of tuples
%%      present in them, false otherwise.
%% @end
-spec compare_proplists(proplists:proplist(), proplists:proplist()) ->
    boolean().
compare_proplists(Prop1, Prop2) ->
    lists:ukeysort(1, Prop1) =:= lists:ukeysort(1, Prop2).

%% @doc Wait for a monitored process to exit
%% @end
-spec wait(reference() | pid) -> ok.
wait(MRef) when is_reference(MRef) ->
    receive {'DOWN', MRef, process, _, _} -> ok end;

wait(Pid) when is_pid(Pid) ->
    MRef = erlang:monitor(process, Pid),
    wait(MRef).


%% @doc Wait for a message to arrive
%% @end
-spec expect(term()) -> ok.
expect(Message) ->
    receive Message -> ok end.

%% @doc Return the first message from the inbox
%% @end
-spec first() -> term().
first() ->
    receive Message -> Message end.


%% @doc Shutdown a child process
%% @end
-spec shutdown(pid()) -> ok.
shutdown(Pid) ->
    MRef = erlang:monitor(process, Pid),
    unlink(Pid),
    exit(Pid, shutdown),
    wait(MRef).

%% @doc Ensure that a previous message has been handled
%% @end
-spec ping(pid() | [pid()]) -> ok.
ping(Pid) when is_pid(Pid) ->
    {status, Pid, _, _} = sys:get_status(Pid),
    ok;

ping(Pids) ->
    [ping(Pid) || Pid <- Pids],
    ok.


%% @doc Handle a gen_server call using a function
%% @end
-spec reply(fun((term()) -> term())) -> ok.
reply(Handler) ->
    receive {'$gen_call', Client, Call} ->
        gen_server:reply(Client, Handler(Call))
    end.


%% @doc Return the first element in the list that matches a condition
%% If no element matched the condition 'false' is returned.
%% @end
-spec find(fun((term()) -> boolean()), [term]) -> false | term().
find(_, []) ->
    false;

find(Condition, [H|T]) ->
    case Condition(H) of
        true  -> H;
        false -> find(Condition, T)
    end.
    

%% @doc Register the local process under a local name
%% @end
-spec register(tuple()) -> true.
register(Name) ->
    gproc:add_local_name(Name).

%% @doc Register the local process as a member of a group
%% @end
-spec register_member(tuple()) -> true.
register_member(Group) ->
    gproc:reg({p, l, Group}, member).


%% @doc Unregister the local process from a name
%% @end
-spec unregister(tuple()) -> true.
unregister(Name) ->
    gproc:unreg({n, l, Name}).

%% @doc Unregister the local process as a member of a group
%% @end
-spec unregister_member(tuple()) -> true.
unregister_member(Group) ->
    gproc:unreg({p, l, Group}).


%% @doc Resolve a local name to a pid
%% @end
-spec lookup(tuple()) -> pid().
lookup(Name) ->
    gproc:lookup_pid({n, l, Name}).

%% @doc Lookup the process id's of all members of a group
%% @end
-spec lookup_members(tuple()) -> [pid()].
lookup_members(Group) ->
    gproc:lookup_pids({p, l, Group}).


%% @doc Wait until a process registers under a local name
%% @end
-spec await(tuple()) -> pid().
await(Name) ->
    await(Name, 5000).

-spec await(tuple(), non_neg_integer()) -> pid().
await(Name, Timeout) ->
    {Pid, undefined} = gproc:await({n, l, Name}, Timeout),
    Pid.




%%====================================================================



%% @doc Convert base32 binary to integer.
%% This function is based on code https://github.com/andrewtj/base32_erlang
%% License: Apache 2
%%
%% Description: http://www.ietf.org/rfc/rfc3548.txt
base32_binary_to_integer(<<Base32Bin:32/binary>>) ->
    Bin = << <<(std_dec(X)):5>> || <<X>> <= Base32Bin>>,
    <<Int:160>> = Bin,
    Int.

std_dec(I) when I >= $2 andalso I =< $7 -> I - 24;
std_dec(I) when I >= $a andalso I =< $z -> I - $a;
std_dec(I) when I >= $A andalso I =< $Z -> I - $A.

format_address({{A,B,C,D}, Port}) ->
    io_lib:format("~B.~B.~B.~B:~B", [A,B,C,D,Port]);
format_address(Addr) ->
    io_lib:format("~p", [Addr]).

init_random_generator() ->
    crypto2:init_random_generator().

sha(Data) ->
    crypto2:sha(Data).
