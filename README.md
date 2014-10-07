# dht — Distributed Hash Table for Erlang

The `dht` application implements a Distributed Hash Table for Erlang. It is hashed from the etorrent application in order to make it possible to use it without using the rest of etorrent.

The current state of the code is that it is not ready yet for many reasons

## Analysis

The code here is excised from ETorrent. We want to hammer on the code until it works and begins to provide a working system. To do this, we will start out simple and then gradually make the code base work as it should in a larger setting. The trick is to run the code through several milestones, each one layering on top of the milestone which came before. The code is currently in an unknown state, so the goal is to establish exactly what works, what doesn't and how things are working or not.

* The first goal is to be able to boot up the dht application. It should not crash.

## TODO List:

haphazard things we should do.

* OK We need to remove `etorrent_…` references from the code base.
* Split the BitTorrent protocol from dht_net. This will enable plugable protocols going forward.
* We need to read through the code and rewrite parts of it when necessary.
* The API could probably do with some help. We currently use the API from etorrent, but the return values might not be good for a general purpose system. So go through the return values and alter them accordingly.
* We have to decide on the types in the API. Currently the API doesn't work like it should.

