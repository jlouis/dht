# dht — Distributed Hash Table for Erlang

The `dht` application implements a Distributed Hash Table for Erlang. It is hashed from the etorrent application in order to make it possible to use it without using the rest of etorrent.

The code is highly rewritten by now. There are few traces left of the original code base. The reason for the partial rewrite was to support a full QuickCheck model, so code was changed in order to make certain parts easier to handle from a formal point of view.

The short overview is that this DHT has the following qualities:

* Stores a mapping from *identities* (256 bit keys) to pairs of `{IP, Port}` on which you can find the value with said identity. Thus, the hash table stores no data itself, but leaves data storage to an external entity entirely. You can use any storage system on the target IP/Port as you see fit.
* Uses the Kademlia protocol to implement a distributed hash table in order to spread out identities over multiple known nodes.
* Storage is *probalistic*. There is a small chance a given entry will go away if the "right" nodes dies. The system will however, if implemented correctly, reinstate the stored value in at most 1 hour if this happens. The more nodes you have, the less the risk of identity mapping loss.
* Lookup is logarithmic and gradually covers the 256 bit space. Thus, lookup is usually not extremely fast, but it is extremely durable. In order words, it is not a DHT for fast lookup.

The current state of the code is that it is not ready yet for many reasons. We are slowly moving in the right direction, rewriting pieces of the code base and redesigning more and more of the system so it is free of the etorrent clutches. But cleaning up an old code base will take some time to pull off and it is not a fast job that happens quickly.

While here, a lot of decisions has to be made in order to ensure future stability of the code base. So focus is on clear code and simple solutions to problems.

## QuickCheck

The "research project" which is being done in this project is to provide a full QuickCheck model of every part of the DHT code. This work has already uncovered numerous grave errors and mistakes in the original etorrent code base, to the point where I'm wondering if this code even worked appropriately in the first place.

Hence, the modeling work continues. It is slowly moving, because you often need to do successive refinement on the knowledge you have as you go along. On the other hand, the parts which have been checked are likely to be formally correct. Far more than any other project.

The current effort is centered around the construction of the top level binding code, that makes everything fit together. This code has not been handled by a QuickCheck model yet, however.

# TODO List:

* Cover the remaining parts of the code base
* Consider the construction of a false “universe” so we can simulate what the rest of the world is storing at a given point in time.
* Simple tests on a 1-node network should behave as expected
