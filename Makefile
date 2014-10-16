PROJECT = dht

.DEFAULT_GOAL := all

# Options.
ERLC_OPTS = +debug_info # +'{parse_transform, lager_transform}'
PLT_APPS = crypto public_key ssl asn1
DIALYZER_OPTS = --fullpath

# Dependencies.
DEPS = recon
#dep_lager = https://github.com/basho/lager.git 2.0.3
dep_recon = https://github.com/ferd/recon.git master


# Standard targets.

analyze:
	@dialyzer ebin --no_native $(DIALYZER_OPTS)

# EQC
eqc-ci: ERLC_OPTS+= +'{parse_transform, eqc_cover}'
eqc-ci: all
	erlc +debug_info +'{parse_transform, eqc_cover}' -o ebin eqc_test/*.erl

include erlang.mk

