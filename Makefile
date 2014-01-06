all_modules  := ddrescue
test_modules := ddrescue 
docdir       := doc

all_sources  := $(foreach m,$(all_modules),$(m).d)
test_progs   := $(foreach m,$(test_modules),test-$(m))
test_targets := $(foreach m,$(test_modules),$(m).lst)

unittest: $(test_targets)
.PHONY: unittest

.INTERMEDIATE: $(test_progs)

%.lst: test-%
	./$<

test-%: %.d testmain.d
	dmd -g -debug -unittest -cov $^ -of$@

testmain.d:
	echo "void main() {}" >$@

doc: $(all_sources) README.html
	dmd -o- -Dd$(docdir) $(all_sources)
.PHONY: doc

README.html: README.md
	markdown $< >$@

clean:
	rm -f testmain.d testmain.lst $(test_targets)
	rm -rf doc/
.PHONY: clean

.DELETE_ON_ERROR: