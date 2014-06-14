# dht — Distributed Hash Table for Erlang

The `dht` application implements a Distributed Hash Table for Erlang. It is hashed from teh etorrent application in order to make it possible to use it without using rest of etorrent.

The current state of the code is that it is not ready yet:

* We need to remove `etorrent_…` references from the code base.
* We need to read through the code and rewrite parts of it when necessary.
