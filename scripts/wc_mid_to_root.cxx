#include <algorithm>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <limits>
#include <string>
#include <vector>

#include "midasio.h"
#include "TFile.h"
#include "TH1F.h"
#include "TTree.h"

namespace {

struct Options {
  std::string input_file;
  std::string output_file;
  long long max_events = -1;
};

void usage(const char* argv0)
{
  std::cerr
      << "Usage: " << argv0 << " --input RUN.mid[.lz4] [--output OUT.root] [--max-events N]\n";
}

bool parse_int64(const char* s, long long* out)
{
  if (!s || !*s) return false;
  char* end = nullptr;
  long long v = strtoll(s, &end, 10);
  if (!end || *end != '\0') return false;
  *out = v;
  return true;
}

bool parse_args(int argc, char** argv, Options* opt)
{
  for (int i = 1; i < argc; i++) {
    const std::string a = argv[i];
    if (a == "--input" && i + 1 < argc) {
      opt->input_file = argv[++i];
    } else if (a == "--output" && i + 1 < argc) {
      opt->output_file = argv[++i];
    } else if (a == "--max-events" && i + 1 < argc) {
      long long v = -1;
      if (!parse_int64(argv[++i], &v) || v < 0) return false;
      opt->max_events = v;
    } else if (a == "-h" || a == "--help") {
      usage(argv[0]);
      return false;
    } else {
      return false;
    }
  }

  if (opt->input_file.empty()) return false;
  if (opt->output_file.empty()) {
    opt->output_file = opt->input_file;
    const std::string suffix_lz4 = ".mid.lz4";
    const std::string suffix_mid = ".mid";
    if (opt->output_file.size() >= suffix_lz4.size() &&
        opt->output_file.compare(opt->output_file.size() - suffix_lz4.size(), suffix_lz4.size(), suffix_lz4) == 0) {
      opt->output_file.erase(opt->output_file.size() - suffix_lz4.size());
    } else if (opt->output_file.size() >= suffix_mid.size() &&
               opt->output_file.compare(opt->output_file.size() - suffix_mid.size(), suffix_mid.size(), suffix_mid) == 0) {
      opt->output_file.erase(opt->output_file.size() - suffix_mid.size());
    }
    opt->output_file += ".root";
  }
  return true;
}

} // namespace

int main(int argc, char** argv)
{
  Options opt;
  if (!parse_args(argc, argv, &opt)) {
    usage(argv[0]);
    return 2;
  }

  TMReaderInterface* reader = TMNewReader(opt.input_file.c_str());
  if (!reader || reader->fError) {
    std::cerr << "Failed to open MIDAS input: " << opt.input_file << "\n";
    if (reader && reader->fError) std::cerr << reader->fErrorString << "\n";
    return 1;
  }

  TFile out(opt.output_file.c_str(), "RECREATE");
  if (out.IsZombie()) {
    std::cerr << "Failed to create ROOT output: " << opt.output_file << "\n";
    reader->Close();
    delete reader;
    return 1;
  }

  TTree tree("wc_events", "WaveCatcher events converted from MIDAS");

  uint32_t midas_serial = 0;
  uint32_t midas_timestamp = 0;
  uint16_t midas_event_id = 0;
  uint32_t wc_event_id = 0;
  uint64_t wc_tdc = 0;
  uint32_t wc_header_nchannels = 0;

  std::vector<int> channel_id;
  std::vector<float> trig_count;
  std::vector<float> time_count;
  std::vector<float> baseline;
  std::vector<float> peak;
  std::vector<float> charge;

  std::vector<int> wf_channel;
  std::vector<int> wf_offset;
  std::vector<int> wf_n_samples;
  std::vector<float> wf_samples;

  tree.Branch("midas_serial", &midas_serial);
  tree.Branch("midas_timestamp", &midas_timestamp);
  tree.Branch("midas_event_id", &midas_event_id);
  tree.Branch("wc_event_id", &wc_event_id);
  tree.Branch("wc_tdc", &wc_tdc);
  tree.Branch("wc_header_nchannels", &wc_header_nchannels);
  tree.Branch("channel_id", &channel_id);
  tree.Branch("trig_count", &trig_count);
  tree.Branch("time_count", &time_count);
  tree.Branch("baseline", &baseline);
  tree.Branch("peak", &peak);
  tree.Branch("charge", &charge);
  tree.Branch("wf_channel", &wf_channel);
  tree.Branch("wf_offset", &wf_offset);
  tree.Branch("wf_n_samples", &wf_n_samples);
  tree.Branch("wf_samples", &wf_samples);

  TH1F h_peak("h_peak_mV", "WCFE peak;mV;entries", 200, -200.0, 600.0);
  TH1F h_charge("h_charge_arb", "WCFE charge;arb;entries", 300, -5000.0, 50000.0);

  long long midas_events = 0;
  long long converted_events = 0;
  while (TMEvent* event = TMReadEvent(reader)) {
    midas_events++;

    if (opt.max_events >= 0 && converted_events >= opt.max_events) {
      delete event;
      break;
    }

    midas_serial = event->serial_number;
    midas_timestamp = event->time_stamp;
    midas_event_id = event->event_id;
    wc_event_id = 0;
    wc_tdc = 0;
    wc_header_nchannels = 0;
    channel_id.clear();
    trig_count.clear();
    time_count.clear();
    baseline.clear();
    peak.clear();
    charge.clear();
    wf_channel.clear();
    wf_offset.clear();
    wf_n_samples.clear();
    wf_samples.clear();

    event->FindAllBanks();
    TMBank* b_wchd = event->FindBank("WCHD");
    TMBank* b_wcfe = event->FindBank("WCFE");
    TMBank* b_wcwf = event->FindBank("WCWF");

    if (!b_wchd && !b_wcfe && !b_wcwf) {
      delete event;
      continue;
    }

    if (b_wchd && b_wchd->data_size >= 4u * sizeof(uint32_t)) {
      const uint32_t* v = reinterpret_cast<const uint32_t*>(event->GetBankData(b_wchd));
      wc_event_id = v[0];
      wc_tdc = (static_cast<uint64_t>(v[2]) << 32) | static_cast<uint64_t>(v[1]);
      wc_header_nchannels = v[3];
    }

    if (b_wcfe && b_wcfe->data_size >= 6u * sizeof(float)) {
      const float* fv = reinterpret_cast<const float*>(event->GetBankData(b_wcfe));
      const size_t n = b_wcfe->data_size / sizeof(float);
      const size_t groups = n / 6;
      channel_id.reserve(groups);
      trig_count.reserve(groups);
      time_count.reserve(groups);
      baseline.reserve(groups);
      peak.reserve(groups);
      charge.reserve(groups);
      for (size_t i = 0; i < groups; i++) {
        const size_t base = i * 6;
        channel_id.push_back(static_cast<int>(fv[base + 0]));
        trig_count.push_back(fv[base + 1]);
        time_count.push_back(fv[base + 2]);
        baseline.push_back(fv[base + 3]);
        peak.push_back(fv[base + 4]);
        charge.push_back(fv[base + 5]);
        h_peak.Fill(fv[base + 4]);
        h_charge.Fill(fv[base + 5]);
      }
    }

    if (b_wcwf && b_wcwf->data_size >= 2u * sizeof(float)) {
      const float* wf = reinterpret_cast<const float*>(event->GetBankData(b_wcwf));
      const size_t n = b_wcwf->data_size / sizeof(float);
      size_t i = 0;
      while (i + 2 <= n) {
        const int ch = static_cast<int>(wf[i++]);
        const int ns = static_cast<int>(wf[i++]);
        if (ns < 0 || i + static_cast<size_t>(ns) > n) {
          break;
        }
        wf_channel.push_back(ch);
        wf_offset.push_back(static_cast<int>(wf_samples.size()));
        wf_n_samples.push_back(ns);
        wf_samples.insert(wf_samples.end(), wf + i, wf + i + ns);
        i += static_cast<size_t>(ns);
      }
    }

    tree.Fill();
    converted_events++;
    delete event;
  }

  out.Write();
  out.Close();
  reader->Close();
  delete reader;

  std::cout << "Converted MIDAS events: " << converted_events << " / scanned: " << midas_events << "\n";
  std::cout << "ROOT output: " << opt.output_file << "\n";
  return 0;
}

