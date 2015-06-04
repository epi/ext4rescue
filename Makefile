all_modules  := bits blockcache ddrescue defs ext4 rescue/file rescue/scan rescue/cache
test_modules := bits blockcache ddrescue ext4 rescue/file
docdir       := doc

all_sources  := $(foreach m,$(all_modules),$(m).d)
test_progs   := $(subst /,-,$(foreach m,$(test_modules),test-$(m)))
test_targets := $(subst /,-,$(foreach m,$(test_modules),$(m).lst))
test_prog_objs := $(addsuffix .o,$(test_progs))

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

test-rescue-%: rescue/%.d testmain.d test.a
	dmd -g -debug -unittest -cov $^ -of$@

testmain.d:
	echo "void main() {}" >$@

doc: $(all_sources) ext4rescue.ddoc README.html
	dmd -o- -Dd$(docdir) $(all_sources) ext4rescue.ddoc
.PHONY: doc

README.html: README.md
	markdown $< >$@

clean:
	rm -f ext4rescue testmain.d testmain.lst test.a $(test_targets) $(test_progs) $(test_prog_objs)
	rm -f doc/*.html
.PHONY: clean

.DELETE_ON_ERROR:
