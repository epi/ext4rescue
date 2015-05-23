all_modules  := bits blockcache ddrescue defs ext4 rescue
test_modules := bits blockcache ddrescue ext4
docdir       := doc

all_sources  := $(foreach m,$(all_modules),$(m).d)
test_progs   := $(foreach m,$(test_modules),test-$(m))
test_targets := $(foreach m,$(test_modules),$(m).lst)

all: ext4rescue
all: DFLAGS = -release -inline
.PHONY: all

debug: ext4rescue 
debug: DFLAGS = -debug -g
.PHONY: debug

ext4rescue: $(all_sources) main.d
	dmd $^ -of$@ $(DFLAGS)

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

doc: $(all_sources) ext4rescue.ddoc README.html
	dmd -o- -Dd$(docdir) $(all_sources) ext4rescue.ddoc
.PHONY: doc

README.html: README.md
	markdown $< >$@

clean:
	rm -f ext4rescue testmain.d testmain.lst test.a $(test_targets)
	rm -f doc/*.html
.PHONY: clean

.DELETE_ON_ERROR:
