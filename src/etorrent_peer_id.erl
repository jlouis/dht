-module(etorrent_peer_id).
-export([peer_id/2]).

%% Returns binary.
-spec peer_id(ClientName::atom(), Version::atom()) -> etorrent_types:peer_id().
peer_id(mu_torrent, '3.0') ->
      % <<"-UT3000-640308218333">>
      id6("UT3000").


%% @doc Encode client version of length 6.
id6(Id) ->
    %% Get a random number from 0 to 999999999999 (12 nines).
    Rand = crypto:rand_uniform(0, 1000000000000),
    iolist_to_binary(io_lib:format("-~s-~-12..-B", [Id, Rand])).

