REBAR=rebar3

compile:
	$(REBAR) compile | sed -e 's|_build/default/lib/dht/||g'

dialyzer:
	$(REBAR) dialyzer | sed -e 's|_build/default/lib/dht/||g'

rel release:
	$(REBAR) release

shell:
	$(REBAR) shell

eqc-ci:
	$(REBAR) compile
	cp eqc_test/*.erl src
	mkdir -p ebin
	erl -make


