-module(dht_store).
-behaviour(gen_server).

%% lifetime API
-export([start_link/0]).

%% gen_server API
-export([init/1, handle_cast/2, handle_call/3, terminate/2, code_change/3, handle_info/2]).

%% API
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% Callbacks
init([]) ->
    {ok, ok}.
	
handle_call(_Msg, _From, State) ->
    {reply, {error, unknown_msg}, State}.
	
handle_cast(_Msg, State) ->
    {noreply, State}.
    
handle_info(_Msg, State) ->
    {noreply, State}.
    
terminate(_How, _State) ->
    ok.
    
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.
