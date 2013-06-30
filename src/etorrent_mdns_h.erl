-module(etorrent_mdns_h).
-behaviour(gen_event).

-export([init/1,
	 terminate/2,
	 handle_info/2,
	 handle_call/2,
	 handle_event/2,
     code_change/3]).

-define(ST, "_bittorrent._tcp").
-define(not_me(Name, State), (Name =/= State#state.my_peer_id)).
-define(is_ip(IP), is_tuple(IP)).
-define(is_bt_port(X), (is_integer(X) andalso (X) >= 1024)).
-record(state, {
    my_peer_id
}).

init([MyPeerId]) ->
    S = #state{
        my_peer_id=MyPeerId
    },
    {ok, S}.

terminate(remove_handler, _) ->
    ok;
terminate(stop, _) ->
    ok;
terminate(Error, State) ->
    error_logger:error_report([{module, ?MODULE},
			       {self, self()},
			       {error, Error},
			       {state, State}]).

handle_event({service_up, Name, ?ST, IP, ServicePort}, State)
    when ?not_me(Name, State), ?is_ip(IP), ?is_bt_port(ServicePort) ->
    etorrent_mdns_state:remote_peer_up(Name, IP, ServicePort),
    {ok, State};
handle_event({service_down, Name, ?ST, IP, ServicePort}, State)
    when ?not_me(Name, State), ?is_ip(IP), ?is_bt_port(ServicePort) ->
    etorrent_mdns_state:remote_peer_down(Name, IP, ServicePort),
    {ok, State};
handle_event({sub_service_up, Name, ?ST, IP, "_" ++ SubType}, State)
    when ?not_me(Name, State), ?is_ip(IP) ->
    etorrent_mdns_state:remote_torrent_up(Name, IP, SubType),
    {ok, State};
handle_event({sub_service_down, Name, ?ST, IP, "_" ++ SubType}, State)
    when ?not_me(Name, State), ?is_ip(IP) ->
    etorrent_mdns_state:remote_torrent_down(Name, IP, SubType),
    {ok, State};
handle_event({service_request, ?ST, IP}, State)
    when ?is_ip(IP) ->
    etorrent_mdns_state:remote_announce_request(IP),
    {ok, State};
handle_event(_Event, State) ->
    lager:debug("Ignore event ~p.", [_Event]),
    {ok, State}.

handle_info({'EXIT', _, shutdown}, _) ->
    remove_handler.

handle_call(_, _) ->
    error(badarg).

code_change(_, _, State) ->
    {ok, State}.
