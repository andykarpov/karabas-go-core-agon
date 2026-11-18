# Ф0 sims: make -> iss (fast ISS for the VDP firmware)
all: iss

iss: iss.cpp
	g++ -O2 -march=native -o $@ $<

clean:
	rm -f iss
.PHONY: all clean
