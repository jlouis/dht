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

# Testing the DHT

This section describes how to use the DHT before we have a bootstrap process into the system. The system is early alpha, so things might not work entirely as expected. I'm interested in any kind of error you see when trying to run this.

DHTs are learners algorithms. They learn about other peers when they communicate with other peers. If they know of no peers, the question is how one manages to start out. Usually one requests a number of bootstrap nodes and injects those blindly into the DHTs routing table at the start of the system. But a smarter way, when toying around, is just to ping a couple of other nodes which runs the DHT code. Once the DHT has run for a while, it will remember its routing table on disk, so then it should be able to start from the on-disk state.

Nodes needs to be “reachable” which means there are no firewall on the peer which makes it unable to respond.

To start out, set a port and start the DHT code:

	application:load(dht),
	application:set_env(dht, port, 1729),
	application:ensure_all_started(dht).
	
Do this on all nodes for which you want to run the DHT. If testing locally, you can pick different port numbers, but you probably also want to set the state file on disk differently in that case.

Ping the other node:

	dht:ping({{192,168,1,123}, 1729}).
	
At this point, the two nodes ought to know about each other. Then you can proceed to use the DHT:

	dht:enter(ID, Port).
	
will make the DHT remember that the entry identified by `ID` can be obtained on the IP of this node, on `Port`. A good way
to get at `ID` for a value `Value` is simply to call `ID = crypto:hash(sha256, Value)`. To look up a handler for an ID, use

	3> dht:lookup(ID).
	[{{172,16,1,200},12345}]
	
which means `ID` can be found at `{172,16,1,200}` on port `12345`. The DHT does not specify the protocol to use there. But one could just define it is HTTP/1.1 and you then request `http://172.16.1.200:12345/ID`. It could also be another protocol, at your leisure.

## QuickCheck

The "research project" which is being done in this project is to provide a full QuickCheck model of every part of the DHT code. This work has already uncovered numerous grave errors and mistakes in the original etorrent code base, to the point where I'm wondering if this code even worked appropriately in the first place.

Hence, the modeling work continues. It is slowly moving, because you often need to do successive refinement on the knowledge you have as you go along. On the other hand, the parts which have been checked are likely to be formally correct. Far more than any other project.

The current effort is centered around the construction of the top level binding code, that makes everything fit together. This code has not been handled by a QuickCheck model yet, however. What *has* been handled already though, is all the low-level parts: network code, routing stable state code and so on.

# TODO List:

* Cover the remaining parts of the code base
* Consider the construction of a false “universe” so we can simulate what the rest of the world is storing at a given point in time.
* Simple tests on a 1-node network should behave as expected
