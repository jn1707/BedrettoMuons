# Minimal MIDAS WaveCatcher frontend build (v2.8.8 pinned)
CXX ?= g++
CXXFLAGS ?= -O2 -Wall

MIDAS_INC ?= $(HOME)/packages/midas/include
MIDAS_LIB ?= $(HOME)/packages/midas/lib
WC_INC_DIR ?= $(HOME)/.local/include/WaveCatcher
WC_V288_LIB_DIR ?= $(HOME)/.local/lib/wavecatcher/v288/lib
WC_LIB_FILE ?= $(WC_V288_LIB_DIR)/libWaveCatcher64ch_v288.so

MIDAS_FE_LIBS ?= -L$(MIDAS_LIB) -lmfe -lmidas -lpthread -lrt
WC_LIBS ?= $(WC_LIB_FILE) -Wl,-rpath,$(WC_V288_LIB_DIR)

all: wc_midas_frontend

wc_midas_frontend: wc_midas_frontend.cxx
	$(CXX) $(CXXFLAGS) -I$(MIDAS_INC) -I$(WC_INC_DIR) -o $@ wc_midas_frontend.cxx $(MIDAS_FE_LIBS) $(WC_LIBS)

clean:
	rm -f wc_midas_frontend

.PHONY: all clean
