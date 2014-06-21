# dht — Distributed Hash Table for Erlang

The `dht` application implements a Distributed Hash Table for Erlang. It is hashed from teh etorrent application in order to make it possible to use it without using rest of etorrent.

The current state of the code is that it is not ready yet:

* We need to remove `etorrent_…` references from the code base.
* We need to read through the code and rewrite parts of it when necessary.
* The API could probably do with some help. We currently use the API from etorrent, but the return values might not be good for a general purpose system. So go through the return values and alter them accordingly.
* The types for infohash and nodeid's should be <<_:160>>. You are not supposed to do arithmetic on them.
