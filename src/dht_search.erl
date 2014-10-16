-module(dht_search).

%% API for iterative search functions
-export([
    find/2
]).

-define(SEARCH_WIDTH, 32).
-define(SEARCH_RETRIES, 4).

%% SEARCH API
%% ---------------------------------------------------

-spec find(find_node | find_value, dht:node_id()) -> list(dht:node_t()).
find(Type, ID) ->
    search_iterate(Type, ID, ?SEARCH_WIDTH, dht_state:closest_to(ID, ?SEARCH_WIDTH)).

%% Internal functions
%% -----------------------------

search_iterate(QType, Target, Width, Nodes)  ->
	NodeID = dht_state:node_id(),
    dht_iter_search(NodeID, QType, Target, Width, ?SEARCH_RETRIES, Nodes,
                    gb_sets:empty(), gb_sets:empty(), []).

dht_iter_search(_NodeID, find_node, _Target, _Width, 0, _Todo, _Done, Alive, _Acc) ->
    gb_sets:to_list(Alive);
dht_iter_search(_NodeID, find_value, _Target, _Width, 0, _Todo, _Done, Alive, Acc) ->
    Store = [{N, Token} || {N, Token, _Vs} <- Acc],
    Found = [V || {_, _, Vs} <- Acc, V <- Vs],
    {Store, Found, gb_sets:to_list(Alive)};
dht_iter_search(NodeID, QType, Target, Width, Retries, Todo, Done, Alive, Acc) ->

    %% Call the DHT in parallel to speed up the search:
    Call = fun({_, IP, Port} = N) -> {N, apply(dht_net, QType, [IP, Port, Target])} end,
    Results = dht_par:pmap(Call, Todo),

    %% Maintain invriants for the next round by updating the necessary data structures:

    %% Mark all nodes that responded as alive
    Living = gb_sets:union(Alive, gb_sets:from_list(alive_nodes(Results))),
    Queried = gb_sets:union(Done, gb_sets:from_list(Todo)),
    New = [N || N <- all_nodes(Results),
                not gb_sets:is_member(N, Queried)],
    WorkQueue = lists:usort(dht_metric:neighborhood(Target, New, Width)),
    Retry =
      case view_closest_node(NodeID, Living, WorkQueue) of
        work_queue -> ?SEARCH_RETRIES;
        alive_set -> Retries - 1
      end,
    Found = accum_peers(QType, Acc, Results),

    dht_iter_search(NodeID, QType, Target, Width, Retry, WorkQueue, Queried, Living, Found).

%% all_nodes/1 gathers nodes from a set of parallel queries
all_nodes(Resp) ->
    Nodes = fun ({nodes, _, Ns}) -> Ns;
                (_) -> []
            end,
    lists:concat([Nodes(R) || {_N, R} <- Resp]).
    
%% alive_nodes/1 returns the nodes returned positive results
alive_nodes(Resp) ->
    OK = fun ({error, _}) -> false;
             ({error, _ID, _Code, _Msg}) -> false;
             (_) -> true
         end,
    [N || {N, R} <- Resp, OK(R)].

%% accum_peers/2 accumulates new targets with the value present
accum_peers(find_node, [], _Results) -> []; % find_node never has results to accumulate
accum_peers(find_value, Acc, Results) ->
    New = [{Node, Token, Vs} || {Node, {values, _, Token, Vs}} <- Results,
                                   Vs /= [] ],
    New ++ Acc.

%% Check if the closest node in the work queue is closer
%% to the target than the closest responsive node that was
%% found in this iteration.
view_closest_node(ID, AliveNodes, WorkQueue) ->
    D = fun({NID, _, _}, M) -> min(M, dht_metric:d(ID, NID)) end,
    MinA = gb_sets:fold(D, infinity, AliveNodes),
    MinQ = lists:foldl(D, infinity, WorkQueue),
    case MinQ < MinA of
        true -> work_queue;
        false -> alive_set
    end.
