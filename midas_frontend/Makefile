# Makefile for building MIDAS WaveCatcher frontend and test harness
CC ?= gcc
CXX ?= g++
CFLAGS ?= -O2 -Wall
CXXFLAGS ?= -O2 -Wall
# Adjust these paths to your MIDAS and WaveCatcher install locations
MIDAS_INC ?= $(HOME)/packages/midas/include
MIDAS_LIB ?= $(HOME)/packages/midas/lib
WC_INC_DIR ?= $(HOME)/.local/include/WaveCatcher
WC_V288_LIB_DIR ?= $(HOME)/.local/lib/wavecatcher/v288/lib
WC_LIB_DIR ?= $(WC_V288_LIB_DIR)
WC_LIB_FILE ?= $(WC_LIB_DIR)/libWaveCatcher64ch_v288.so
MIDAS_FE_LIBS ?= -L$(MIDAS_LIB) -lmfe -lmidas -lpthread -lrt
WC_LIBS ?= $(WC_LIB_FILE) -Wl,-rpath,$(WC_LIB_DIR)

all: wc_test_harness wc_api_smoke_test wc_midas_frontend

wc_test_harness: wc_test_harness.c
	$(CC) $(CFLAGS) -I$(WC_INC_DIR) -o $@ wc_test_harness.c $(WC_LIBS)

wc_api_smoke_test: wc_api_smoke_test.c
	$(CC) $(CFLAGS) -I$(WC_INC_DIR) -o $@ wc_api_smoke_test.c $(WC_LIBS)

wc_midas_frontend: wc_midas_frontend.cxx
	$(CXX) $(CXXFLAGS) -I$(MIDAS_INC) -I$(WC_INC_DIR) -o $@ wc_midas_frontend.cxx $(MIDAS_FE_LIBS) $(WC_LIBS)

clean:
	rm -f wc_test_harness wc_api_smoke_test wc_midas_frontend

.PHONY: all clean
