default: debug

debug:
	dub build

release:
	dub build -b release

test:
	dub test -b unittest-cov
	tail -q -n 1 source-*.lst

doc:
	dub build -b ddox
	markdown <README.md >README.html

clean:
	dub clean
	rm -f ext4rescue __test__library__ dub.selections.json docs.json __dummy.html README.html *.lst ..*.lst
	rm -rf docs

.PHONY: default debug release test doc clean
