BIN=bin
.PHONY: all test time example

all:	$(BIN)/eval $(BIN)/uhs

$(BIN)/eval:	eval.c
	@mkdir -p bin
	gcc -Wall -O3 eval.c -o $(BIN)/eval

$(BIN)/uhs:	*.hs
	@mkdir -p bin
	ghc -Wall -O Main.hs -o $(BIN)/uhs

test:	$(BIN)/eval $(BIN)/uhs tests/*.hs
	cd tests; make test

time:	$(BIN)/eval $(BIN)/uhs tests/*.hs
	cd tests; make time

example:	$(BIN)/eval $(BIN)/uhs Example.hs
	$(BIN)/uhs -ilib Example && $(BIN)/eval

clean:
	rm -f *.hi *.o eval Main *.comb *.tmp *~
	cd tests; make clean
