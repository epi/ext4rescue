DMD          = dmd

all_modules  := blockcache ddrescue
test_modules := blockcache ddrescue
docdir       := doc

all_sources  := $(foreach m,$(all_modules),$(m).d)
test_progs   := $(foreach m,$(test_modules),test-$(m))
test_targets := $(foreach m,$(test_modules),$(m).lst)

unittest: $(test_targets)
.PHONY: unittest

.INTERMEDIATE: $(test_progs)

%.lst: test-%
	./$< && grep covered $@

test.a: $(all_sources)
	dmd -g -debug -lib $^ -of$@

test-%: %.d testmain.d test.a
	dmd -g -debug -unittest -cov $^ -of$@

testmain.d:
	echo "void main() {}" >$@

doc: $(all_sources) README.html
	dmd -o- -Dd$(docdir) $(all_sources)
.PHONY: doc

README.html: README.md
	markdown $< >$@

clean:
	rm -f testmain.d testmain.lst test.a $(test_targets)
	rm -rf doc/
.PHONY: clean

.DELETE_ON_ERROR: