# dht — Distributed Hash Table for Erlang

The `dht` application implements a Distributed Hash Table for Erlang. It is hashed from teh etorrent application in order to make it possible to use it without using rest of etorrent.

The current state of the code is that it is not ready yet:

* OK We need to remove `etorrent_…` references from the code base.
* Split the BitTorrent protocol from dht_net. This will enable plugable protocols going forward.
* We need to read through the code and rewrite parts of it when necessary.
* The API could probably do with some help. We currently use the API from etorrent, but the return values might not be good for a general purpose system. So go through the return values and alter them accordingly.
* We have to decide on the types in the API. Currently the API doesn't work like it should.

