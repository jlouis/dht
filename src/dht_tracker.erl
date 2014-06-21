-module(dht_tracker).

-export([announce/3, get_peers/1]).

announce(InfoHash, IP, Port) -> ok.

get_peers(InfoHash) -> [].