#undef NDEBUG

#include <stdio.h>
#include <string.h>
#include <vector>
#include <cmath>
#include <string>
#include <sstream>
#include <algorithm>
#include <thread>

#include "midas.h"
#include "mfe.h"
#include "WaveCat64ch_Lib.h"

const char *frontend_name = "WaveCatcher Frontend";
const char *frontend_file_name = __FILE__;
BOOL frontend_call_loop = TRUE;
INT display_period = 1000;
INT max_event_size = 8 * 1024 * 1024;
INT max_event_size_frag = 16 * 1024 * 1024;
INT event_buffer_size = 32 * 1024 * 1024;
BOOL equipment_common_overwrite = TRUE;

INT frontend_init(void);
INT frontend_exit(void);
INT begin_of_run(INT run_number, char *error);
INT end_of_run(INT run_number, char *error);
INT pause_run(INT run_number, char *error);
INT resume_run(INT run_number, char *error);
INT frontend_loop(void);
INT poll_event(INT source, INT count, BOOL test);
INT read_wavecatcher_event(char *pevent, INT off);
INT interrupt_configure(INT cmd, INT source, POINTER_T adr);

static bool g_run_active = false;
static bool g_device_open = false;
static bool g_device_open_attempted = false;
static bool g_device_open_thread_started = false;
static int g_device_open_state = 0; /* 0=idle, 1=in_progress, 2=ready, 3=failed, 4=timed_out */
static DWORD g_device_open_start_ms = 0;
static DWORD g_device_open_timeout_ms = 180000; /* 3 min */
static int g_last_reported_device_open_state = -1;
static DWORD g_last_device_state_odb_ms = 0;
static bool g_evt_allocated = false;
static WAVECAT64CH_EventStruct g_evt {};

static float g_trigger_threshold_v = 0.030f;
static WAVECAT64CH_TriggerEdgeType g_trigger_edge = WAVECAT64CH_POS_EDGE;
static int g_enabled_channel = 0;
static int g_sw_trigger_hz = 0;
static int g_trigger_mode_odb = 0; /* 0=normal, 1=soft, 2=coincidence */
static int g_coincidence_channel = 1;
static float g_coincidence_threshold_v = 0.050f;
static int g_sampling_frequency_mhz = 3200;
static int g_run_duration_s = 0; /* 0 disables auto-stop */
static std::string g_enabled_channels_csv = "";
static bool g_apply_threshold_to_selected = false;
static float g_selected_threshold_v = 0.030f;
static int g_auto_stop_mode = 0; /* 0=none, 1=duration, 2=event_count */
static int g_target_event_count = 0;
static std::vector<int> g_active_channels;
static std::string g_ui_last_apply_status = "uninitialized";
static std::string g_ui_last_apply_error = "";
static bool g_event_in_buffer = false;
static unsigned long long g_poll_calls = 0;
static unsigned long long g_poll_hits = 0;
static unsigned long long g_decode_calls = 0;
static unsigned long long g_decode_hits = 0;
static unsigned long long g_poll_incomplete = 0;
static unsigned long long g_poll_no_event = 0;
static unsigned long long g_poll_other_err = 0;
static unsigned long long g_wave_nan_only = 0;
static unsigned long long g_wave_channels_written = 0;
static unsigned long long g_wave_size_zero = 0;
static unsigned long long g_wave_ptr_null = 0;
static DWORD g_next_soft_trigger_ms = 0;
static DWORD g_run_start_ms = 0;
static bool g_stop_transition_requested = false;
static bool g_shutdown_requested = false;
static DWORD g_last_live_update_ms = 0;

static void wc_set_device_open_state_odb()
{
   db_set_value(hDB, 0, "/Equipment/WaveCatcher/Variables/device_open_state",
                &g_device_open_state, sizeof(g_device_open_state), 1, TID_INT);
   const char *state_str = "idle";
   if (g_device_open_state == 1) state_str = "in_progress";
   else if (g_device_open_state == 2) state_str = "ready";
   else if (g_device_open_state == 3) state_str = "failed";
   else if (g_device_open_state == 4) state_str = "timed_out";
   db_set_value(hDB, 0, "/Equipment/WaveCatcher/Variables/device_open_state_str",
                state_str, (INT)strlen(state_str) + 1, 1, TID_STRING);
}

static void wc_publish_device_state_if_needed(bool force = false)
{
   DWORD now = ss_millitime();
   if (force || g_device_open_state != g_last_reported_device_open_state ||
       (now - g_last_device_state_odb_ms) > 1000) {
      wc_set_device_open_state_odb();
      g_last_reported_device_open_state = g_device_open_state;
      g_last_device_state_odb_ms = now;
   }
}


static int wc_check(WAVECAT64CH_ErrCode code, const char *where);

static void wc_set_run_summary_value(const char *name, const void *data, INT size, INT tid)
{
   char path[256];
   snprintf(path, sizeof(path), "/Equipment/WaveCatcher/RunSummary/%s", name);
   db_set_value(hDB, 0, path, data, size, 1, tid);
}

static void wc_set_live_value(const char *name, const void *data, INT size, INT tid)
{
   char path[256];
   snprintf(path, sizeof(path), "/Equipment/WaveCatcher/Live/%s", name);
   db_set_value(hDB, 0, path, data, size, 1, tid);
}

static void wc_update_run_summary(INT run_number)
{
   char logger_dir[256] = "/home/morenoma/online_wc/";
   INT size = sizeof(logger_dir);
   db_get_value(hDB, 0, "/Logger/Data dir", logger_dir, &size, TID_STRING, TRUE);

   char run_file[512];
   snprintf(run_file, sizeof(run_file), "%srun%05d.mid.lz4", logger_dir, run_number);
   double elapsed_s = 0.0;
   if (g_run_start_ms > 0) {
      DWORD now_ms = ss_millitime();
      elapsed_s = (double)(now_ms - g_run_start_ms) / 1000.0;
   }
   double rate_hz = (elapsed_s > 0.0) ? ((double)g_decode_hits / elapsed_s) : 0.0;

   int trigger_edge = (int)g_trigger_edge;
   wc_set_run_summary_value("run_number", &run_number, sizeof(run_number), TID_INT);
   wc_set_run_summary_value("run_state", "stopped", 8, TID_STRING);
   wc_set_run_summary_value("events_sent", &g_decode_hits, sizeof(g_decode_hits), TID_QWORD);
   wc_set_run_summary_value("elapsed_s", &elapsed_s, sizeof(elapsed_s), TID_DOUBLE);
   wc_set_run_summary_value("event_rate_hz", &rate_hz, sizeof(rate_hz), TID_DOUBLE);
   wc_set_run_summary_value("trigger_mode", &g_trigger_mode_odb, sizeof(g_trigger_mode_odb), TID_INT);
   wc_set_run_summary_value("trigger_edge", &trigger_edge, sizeof(trigger_edge), TID_INT);
   wc_set_run_summary_value("enabled_channel", &g_enabled_channel, sizeof(g_enabled_channel), TID_INT);
   wc_set_run_summary_value("enabled_channels_csv", g_enabled_channels_csv.c_str(),
                            (INT)g_enabled_channels_csv.size() + 1, TID_STRING);
   wc_set_run_summary_value("trigger_threshold_v", &g_trigger_threshold_v, sizeof(g_trigger_threshold_v), TID_FLOAT);
   wc_set_run_summary_value("coincidence_channel", &g_coincidence_channel, sizeof(g_coincidence_channel), TID_INT);
   wc_set_run_summary_value("coincidence_threshold_v", &g_coincidence_threshold_v, sizeof(g_coincidence_threshold_v), TID_FLOAT);
   wc_set_run_summary_value("sw_trigger_hz", &g_sw_trigger_hz, sizeof(g_sw_trigger_hz), TID_INT);
   wc_set_run_summary_value("auto_stop_mode", &g_auto_stop_mode, sizeof(g_auto_stop_mode), TID_INT);
   wc_set_run_summary_value("run_duration_s", &g_run_duration_s, sizeof(g_run_duration_s), TID_INT);
   wc_set_run_summary_value("target_event_count", &g_target_event_count, sizeof(g_target_event_count), TID_INT);
   wc_set_run_summary_value("last_run_file", run_file, (INT)strlen(run_file) + 1, TID_STRING);
}

static void ensure_odb_schema_defaults()
{
   const char *empty = "";
   BOOL apply_sel = g_apply_threshold_to_selected ? TRUE : FALSE;
   db_set_value(hDB, 0, "/Equipment/WaveCatcher/Variables/enabled_channels_csv",
                g_enabled_channels_csv.c_str(), (INT)g_enabled_channels_csv.size() + 1, 1, TID_STRING);
   db_set_value(hDB, 0, "/Equipment/WaveCatcher/Variables/apply_threshold_to_selected",
                &apply_sel, sizeof(apply_sel), 1, TID_BOOL);
   db_set_value(hDB, 0, "/Equipment/WaveCatcher/Variables/selected_threshold_v",
                &g_selected_threshold_v, sizeof(g_selected_threshold_v), 1, TID_FLOAT);
   db_set_value(hDB, 0, "/Equipment/WaveCatcher/Variables/auto_stop_mode",
                &g_auto_stop_mode, sizeof(g_auto_stop_mode), 1, TID_INT);
   db_set_value(hDB, 0, "/Equipment/WaveCatcher/Variables/target_event_count",
                &g_target_event_count, sizeof(g_target_event_count), 1, TID_INT);
   db_set_value(hDB, 0, "/Equipment/WaveCatcher/Variables/ui_last_apply_status",
                g_ui_last_apply_status.c_str(), (INT)g_ui_last_apply_status.size() + 1, 1, TID_STRING);
   db_set_value(hDB, 0, "/Equipment/WaveCatcher/Variables/ui_last_apply_error",
                empty, 1, 1, TID_STRING);
   const char *help =
      "trigger_mode: 0=normal 1=software 2=coincidence(2-channel: primary+partner) | "
      "trigger_edge: 0=pos 1=neg | "
      "trigger_threshold_v=primary threshold | "
      "selected_threshold_v=bulk threshold for enabled_channels_csv if apply_threshold_to_selected=true | "
      "coincidence_threshold_v=partner threshold | "
      "auto_stop_mode: 0=none 1=duration(run_duration_s) 2=event_count(target_event_count)";
    db_set_value(hDB, 0, "/Equipment/WaveCatcher/Variables/help",
                 help, (INT)strlen(help) + 1, 1, TID_STRING);
    db_set_value(hDB, 0, "/Equipment/WaveCatcher/Variables/device_open_state",
                 &g_device_open_state, sizeof(g_device_open_state), 1, TID_INT);
    db_set_value(hDB, 0, "/Equipment/WaveCatcher/Variables/device_open_state_str",
                 "idle", 5, 1, TID_STRING);

   const char *none = "n/a";
   INT i0 = 0;
   unsigned long long q0 = 0;
   double d0 = 0.0;
   float f0 = 0.0f;
   wc_set_run_summary_value("run_number", &i0, sizeof(i0), TID_INT);
   wc_set_run_summary_value("run_state", "idle", 5, TID_STRING);
   wc_set_run_summary_value("events_sent", &q0, sizeof(q0), TID_QWORD);
   wc_set_run_summary_value("elapsed_s", &d0, sizeof(d0), TID_DOUBLE);
   wc_set_run_summary_value("event_rate_hz", &d0, sizeof(d0), TID_DOUBLE);
   wc_set_run_summary_value("trigger_mode", &i0, sizeof(i0), TID_INT);
   wc_set_run_summary_value("trigger_edge", &i0, sizeof(i0), TID_INT);
   wc_set_run_summary_value("enabled_channel", &i0, sizeof(i0), TID_INT);
   wc_set_run_summary_value("enabled_channels_csv", "", 1, TID_STRING);
   wc_set_run_summary_value("trigger_threshold_v", &f0, sizeof(f0), TID_FLOAT);
   wc_set_run_summary_value("coincidence_channel", &i0, sizeof(i0), TID_INT);
   wc_set_run_summary_value("coincidence_threshold_v", &f0, sizeof(f0), TID_FLOAT);
   wc_set_run_summary_value("sw_trigger_hz", &i0, sizeof(i0), TID_INT);
   wc_set_run_summary_value("auto_stop_mode", &i0, sizeof(i0), TID_INT);
   wc_set_run_summary_value("run_duration_s", &i0, sizeof(i0), TID_INT);
   wc_set_run_summary_value("target_event_count", &i0, sizeof(i0), TID_INT);
   wc_set_run_summary_value("last_run_file", none, 4, TID_STRING);

   wc_set_live_value("preview_channel", &i0, sizeof(i0), TID_INT);
   wc_set_live_value("preview_waveform_csv", "", 1, TID_STRING);
    wc_set_live_value("preview_channels_csv", "", 1, TID_STRING);
    wc_set_live_value("preview_waveforms_encoded", "", 1, TID_STRING);
   wc_set_live_value("preview_samples", &i0, sizeof(i0), TID_INT);
   wc_set_live_value("preview_updated_ms", &i0, sizeof(i0), TID_INT);
}

static void wc_set_ui_status(const std::string &status, const std::string &error)
{
   g_ui_last_apply_status = status;
   g_ui_last_apply_error = error;
   db_set_value(hDB, 0, "/Equipment/WaveCatcher/Variables/ui_last_apply_status",
                g_ui_last_apply_status.c_str(),
                (INT)g_ui_last_apply_status.size() + 1, 1, TID_STRING);
   db_set_value(hDB, 0, "/Equipment/WaveCatcher/Variables/ui_last_apply_error",
                g_ui_last_apply_error.c_str(),
                (INT)g_ui_last_apply_error.size() + 1, 1, TID_STRING);
}

static std::vector<int> parse_channel_csv(const std::string &csv)
{
   std::vector<int> out;
   std::stringstream ss(csv);
   std::string tok;
   while (std::getline(ss, tok, ',')) {
      size_t b = tok.find_first_not_of(" \t");
      if (b == std::string::npos)
         continue;
      size_t e = tok.find_last_not_of(" \t");
      std::string t = tok.substr(b, e - b + 1);
      char *endp = nullptr;
      long v = strtol(t.c_str(), &endp, 10);
      if (*t.c_str() == '\0' || (endp && *endp != '\0'))
         continue;
      if (v < 0 || v > 63)
         continue;
      out.push_back((int)v);
   }
   std::sort(out.begin(), out.end());
   out.erase(std::unique(out.begin(), out.end()), out.end());
   return out;
}

static void refresh_active_channels()
{
   std::vector<int> ch = parse_channel_csv(g_enabled_channels_csv);
   if (g_enabled_channel >= 0 && g_enabled_channel <= 63 &&
       std::find(ch.begin(), ch.end(), g_enabled_channel) == ch.end()) {
      ch.push_back(g_enabled_channel);
   }
   std::sort(ch.begin(), ch.end());
   ch.erase(std::unique(ch.begin(), ch.end()), ch.end());
   if (ch.empty() && g_enabled_channel >= 0 && g_enabled_channel <= 63)
      ch.push_back(g_enabled_channel);
   g_active_channels = ch;
}

static int wc_check(WAVECAT64CH_ErrCode code, const char *where)
{
   if (code == WAVECAT64CH_Success)
      return SUCCESS;
   cm_msg(MERROR, "WaveCatcher", "%s failed with code %d", where, (int)code);
   return FE_ERR_HW;
}

static void load_settings_from_odb()
{
   INT size = 0;
   INT edge_i = 0;
   INT sw_hz = 0;
   INT trig_mode = g_trigger_mode_odb;
   INT coinc_ch = g_coincidence_channel;
   INT channel = 0;
   float threshold = g_trigger_threshold_v;
   float coinc_thr = g_coincidence_threshold_v;
   BOOL apply_thr_selected = g_apply_threshold_to_selected ? TRUE : FALSE;
   float selected_thr = g_selected_threshold_v;
   INT auto_stop_mode = g_auto_stop_mode;
   INT target_event_count = g_target_event_count;
   char channels_csv[256] = "";
   char ui_status[256] = "idle";
   char ui_error[256] = "";
   char help_text[512] =
      "trigger_mode: 0=normal 1=software 2=coincidence(2-channel: primary+partner) | "
      "trigger_edge: 0=pos 1=neg | "
      "trigger_threshold_v=primary threshold | "
      "selected_threshold_v=bulk threshold for enabled_channels_csv if apply_threshold_to_selected=true | "
      "coincidence_threshold_v=partner threshold | "
      "auto_stop_mode: 0=none 1=duration(run_duration_s) 2=event_count(target_event_count)";

   size = sizeof(threshold);
   db_get_value(hDB, 0, "/Equipment/WaveCatcher/Variables/trigger_threshold_v",
                &threshold, &size, TID_FLOAT, TRUE);
   g_trigger_threshold_v = threshold;

   size = sizeof(edge_i);
   db_get_value(hDB, 0, "/Equipment/WaveCatcher/Variables/trigger_edge",
                &edge_i, &size, TID_INT, TRUE);
   g_trigger_edge = (edge_i == 0) ? WAVECAT64CH_POS_EDGE : WAVECAT64CH_NEG_EDGE;

   size = sizeof(channel);
   db_get_value(hDB, 0, "/Equipment/WaveCatcher/Variables/enabled_channel",
                &channel, &size, TID_INT, TRUE);
   g_enabled_channel = channel;

   size = sizeof(sw_hz);
   db_get_value(hDB, 0, "/Equipment/WaveCatcher/Variables/sw_trigger_hz",
                &sw_hz, &size, TID_INT, TRUE);
   g_sw_trigger_hz = sw_hz;

   size = sizeof(trig_mode);
   db_get_value(hDB, 0, "/Equipment/WaveCatcher/Variables/trigger_mode",
                &trig_mode, &size, TID_INT, TRUE);
   g_trigger_mode_odb = trig_mode;

   size = sizeof(coinc_ch);
   db_get_value(hDB, 0, "/Equipment/WaveCatcher/Variables/coincidence_channel",
                &coinc_ch, &size, TID_INT, TRUE);
   g_coincidence_channel = coinc_ch;

   size = sizeof(coinc_thr);
   db_get_value(hDB, 0, "/Equipment/WaveCatcher/Variables/coincidence_threshold_v",
                &coinc_thr, &size, TID_FLOAT, TRUE);
   g_coincidence_threshold_v = coinc_thr;

   size = sizeof(g_sampling_frequency_mhz);
   db_get_value(hDB, 0, "/Equipment/WaveCatcher/Variables/sampling_frequency_mhz",
                &g_sampling_frequency_mhz, &size, TID_INT, TRUE);

   size = sizeof(g_run_duration_s);
   db_get_value(hDB, 0, "/Equipment/WaveCatcher/Variables/run_duration_s",
                &g_run_duration_s, &size, TID_INT, TRUE);

   size = sizeof(channels_csv);
   db_get_value(hDB, 0, "/Equipment/WaveCatcher/Variables/enabled_channels_csv",
                channels_csv, &size, TID_STRING, TRUE);
   g_enabled_channels_csv = channels_csv;
   refresh_active_channels();

   size = sizeof(apply_thr_selected);
   db_get_value(hDB, 0, "/Equipment/WaveCatcher/Variables/apply_threshold_to_selected",
                &apply_thr_selected, &size, TID_BOOL, TRUE);
   g_apply_threshold_to_selected = (apply_thr_selected != 0);

   size = sizeof(selected_thr);
   db_get_value(hDB, 0, "/Equipment/WaveCatcher/Variables/selected_threshold_v",
                &selected_thr, &size, TID_FLOAT, TRUE);
   g_selected_threshold_v = selected_thr;

   size = sizeof(auto_stop_mode);
   db_get_value(hDB, 0, "/Equipment/WaveCatcher/Variables/auto_stop_mode",
                &auto_stop_mode, &size, TID_INT, TRUE);
   g_auto_stop_mode = auto_stop_mode;

   size = sizeof(target_event_count);
   db_get_value(hDB, 0, "/Equipment/WaveCatcher/Variables/target_event_count",
                &target_event_count, &size, TID_INT, TRUE);
   g_target_event_count = target_event_count;

   size = sizeof(ui_status);
   db_get_value(hDB, 0, "/Equipment/WaveCatcher/Variables/ui_last_apply_status",
                ui_status, &size, TID_STRING, TRUE);
   g_ui_last_apply_status = ui_status;

   size = sizeof(ui_error);
   db_get_value(hDB, 0, "/Equipment/WaveCatcher/Variables/ui_last_apply_error",
                ui_error, &size, TID_STRING, TRUE);
   g_ui_last_apply_error = ui_error;

   size = sizeof(help_text);
   db_get_value(hDB, 0, "/Equipment/WaveCatcher/Variables/help",
                help_text, &size, TID_STRING, TRUE);
}

static INT wc_device_open_once()
{
   if (g_device_open) {
      return SUCCESS;
   }

   INT st = FE_ERR_DRIVER;
   int handle = -1;
   for (int attempt = 1; attempt <= 6; ++attempt) {
      cm_msg(MINFO, "WaveCatcher", "OpenDevice attempt=%d", attempt);
      handle = -1;
      st = wc_check(WAVECAT64CH_OpenDevice(&handle), "OpenDevice");
      if (st == SUCCESS) {
         g_device_open = true;
         break;
      }
      ss_sleep(200);
   }
   if (st != SUCCESS) return st;

   st = wc_check(WAVECAT64CH_ResetDevice(), "ResetDevice");
   if (st != SUCCESS) return st;
   st = wc_check(WAVECAT64CH_SetDefaultParameters(), "SetDefaultParameters");
   if (st != SUCCESS) return st;

   return SUCCESS;
}

static void wc_device_open_worker()
{
   g_device_open_state = 1;
   g_device_open_start_ms = ss_millitime();
   wc_publish_device_state_if_needed(true);
   INT st = wc_device_open_once();
   if (st == SUCCESS) {
      g_device_open_state = 2;
   } else {
      g_device_open_state = 3;
   }
   wc_publish_device_state_if_needed(true);
}

static INT wc_apply_run_configuration()
{
   load_settings_from_odb();
   INT st = SUCCESS;
   bool use_coincidence = (g_trigger_mode_odb == 2);
   std::vector<int> selected_channels = parse_channel_csv(g_enabled_channels_csv);
   if (selected_channels.empty())
      selected_channels.push_back(g_enabled_channel);
   if (std::find(selected_channels.begin(), selected_channels.end(), g_enabled_channel) == selected_channels.end())
      selected_channels.push_back(g_enabled_channel);

   wc_set_ui_status("applying", "");

   for (int ch : selected_channels) {
      cm_msg(MINFO, "WaveCatcher", "cfg: SetChannelState ch=%d", ch);
      st = wc_check(
         WAVECAT64CH_SetChannelState(WAVECAT64CH_FRONT_CHANNEL, ch, WAVECAT64CH_STATE_ON),
         "SetChannelState");
      if (st != SUCCESS) {
         wc_set_ui_status("error", "SetChannelState failed");
         return st;
      }
   }

   if (use_coincidence && g_coincidence_channel != g_enabled_channel) {
      cm_msg(MINFO, "WaveCatcher", "cfg: SetChannelState coincidence_ch=%d", g_coincidence_channel);
      st = wc_check(
         WAVECAT64CH_SetChannelState(WAVECAT64CH_FRONT_CHANNEL, g_coincidence_channel, WAVECAT64CH_STATE_ON),
         "SetChannelState(coincidence)");
      if (st != SUCCESS) {
         wc_set_ui_status("error", "SetChannelState(coincidence) failed");
         return st;
      }
   }

   for (int ch : selected_channels) {
      cm_msg(MINFO, "WaveCatcher", "cfg: SetTriggerSourceState ch=%d", ch);
      st = wc_check(
         WAVECAT64CH_SetTriggerSourceState(WAVECAT64CH_FRONT_CHANNEL, ch, WAVECAT64CH_STATE_ON),
         "SetTriggerSourceState");
      if (st != SUCCESS) {
         wc_set_ui_status("error", "SetTriggerSourceState failed");
         return st;
      }
   }

   if (use_coincidence && g_coincidence_channel != g_enabled_channel) {
      cm_msg(MINFO, "WaveCatcher", "cfg: SetTriggerSourceState coincidence_ch=%d", g_coincidence_channel);
      st = wc_check(
         WAVECAT64CH_SetTriggerSourceState(WAVECAT64CH_FRONT_CHANNEL, g_coincidence_channel, WAVECAT64CH_STATE_ON),
         "SetTriggerSourceState(coincidence)");
      if (st != SUCCESS) {
         wc_set_ui_status("error", "SetTriggerSourceState(coincidence) failed");
         return st;
      }
   }

   for (int ch : selected_channels) {
      cm_msg(MINFO, "WaveCatcher", "cfg: SetTriggerEdge ch=%d edge=%d", ch, (int)g_trigger_edge);
      st = wc_check(
         WAVECAT64CH_SetTriggerEdge(WAVECAT64CH_FRONT_CHANNEL, ch, g_trigger_edge),
         "SetTriggerEdge");
      if (st != SUCCESS) {
         wc_set_ui_status("error", "SetTriggerEdge failed");
         return st;
      }
      float thr = g_trigger_threshold_v;
      if (g_apply_threshold_to_selected)
         thr = g_selected_threshold_v;
      cm_msg(MINFO, "WaveCatcher", "cfg: SetTriggerThreshold ch=%d thr=%.3f", ch, thr);
      st = wc_check(
         WAVECAT64CH_SetTriggerThreshold(WAVECAT64CH_FRONT_CHANNEL, ch, thr),
         "SetTriggerThreshold");
      if (st != SUCCESS) {
         wc_set_ui_status("error", "SetTriggerThreshold failed");
         return st;
      }
   }

   if (use_coincidence && g_coincidence_channel != g_enabled_channel) {
      cm_msg(MINFO, "WaveCatcher", "cfg: SetTriggerEdge coincidence_ch=%d edge=%d", g_coincidence_channel, (int)g_trigger_edge);
      st = wc_check(
         WAVECAT64CH_SetTriggerEdge(WAVECAT64CH_FRONT_CHANNEL, g_coincidence_channel, g_trigger_edge),
         "SetTriggerEdge(coincidence)");
      if (st != SUCCESS) return st;

      cm_msg(MINFO, "WaveCatcher", "cfg: SetTriggerThreshold coincidence_ch=%d thr=%.3f", g_coincidence_channel, g_coincidence_threshold_v);
      st = wc_check(
         WAVECAT64CH_SetTriggerThreshold(WAVECAT64CH_FRONT_CHANNEL, g_coincidence_channel, g_coincidence_threshold_v),
         "SetTriggerThreshold(coincidence)");
      if (st != SUCCESS) {
         wc_set_ui_status("error", "SetTriggerThreshold(coincidence) failed");
         return st;
      }
   }

   WAVECAT64CH_TriggerType trig_mode = WAVECAT64CH_TRIGGER_NORMAL;
   if (use_coincidence) {
      trig_mode = WAVECAT64CH_TRIGGER_COINCIDENCE;
   } else if (g_sw_trigger_hz > 0 || g_trigger_mode_odb == 1) {
      trig_mode = WAVECAT64CH_TRIGGER_SOFT;
   }
   cm_msg(MINFO, "WaveCatcher", "cfg: SetTriggerMode mode=%d", (int)trig_mode);
   st = wc_check(WAVECAT64CH_SetTriggerMode(trig_mode), "SetTriggerMode");
   if (st != SUCCESS) return st;

   cm_msg(MINFO, "WaveCatcher", "cfg: PrepareEvent");
   st = wc_check(WAVECAT64CH_PrepareEvent(), "PrepareEvent");
   if (st != SUCCESS) {
      wc_set_ui_status("error", "PrepareEvent failed");
      return st;
   }

    cm_msg(MINFO, "WaveCatcher",
           "BOR settings: ch=%d csv=%s thr=%.3f selected_thr=%.3f apply_selected=%d edge=%d mode=%d odb_mode=%d sw_trigger_hz=%d coinc_ch=%d coinc_thr=%.3f duration_s=%d auto_stop_mode=%d target_events=%d compat=minimal-v288",
           g_enabled_channel, g_enabled_channels_csv.c_str(), g_trigger_threshold_v, g_selected_threshold_v, (int)g_apply_threshold_to_selected,
            (int)g_trigger_edge, (int)trig_mode, g_trigger_mode_odb, g_sw_trigger_hz,
           g_coincidence_channel, g_coincidence_threshold_v,
           g_run_duration_s, g_auto_stop_mode, g_target_event_count);
   wc_set_ui_status("applied", "");
   return SUCCESS;
}

static void wc_stop_close()
{
   if (g_run_active || g_device_open) {
      WAVECAT64CH_ErrCode ec = WAVECAT64CH_StopRun();
      if (ec != WAVECAT64CH_Success) {
         cm_msg(MINFO, "WaveCatcher", "StopRun during cleanup returned %d", (int)ec);
      }
   }
   g_run_active = false;
   g_event_in_buffer = false;
   if (g_evt_allocated) {
      WAVECAT64CH_ErrCode ec = WAVECAT64CH_FreeEventStructure(&g_evt);
      if (ec != WAVECAT64CH_Success) {
         cm_msg(MINFO, "WaveCatcher", "FreeEventStructure during cleanup returned %d", (int)ec);
      }
      g_evt_allocated = false;
   }
   if (g_device_open) {
      WAVECAT64CH_ErrCode ec = WAVECAT64CH_CloseDevice();
      if (ec != WAVECAT64CH_Success) {
         cm_msg(MINFO, "WaveCatcher", "CloseDevice during cleanup returned %d", (int)ec);
      }
      g_device_open = false;
   }
}

EQUIPMENT equipment[] = {
   {"WaveCatcher",
    {1201, 0,
      "SYSTEM",
      EQ_POLLED,
      0,
      "MIDAS",
      TRUE,
      RO_RUNNING | RO_ODB,
      10,
     0,
     0,
     0,
     "", "", "", "", "", 0},
    read_wavecatcher_event,
    NULL,
    NULL,
    NULL,
    NULL},
   {""}
};

INT frontend_init(void)
{
   ensure_odb_schema_defaults();
   load_settings_from_odb();
   cm_msg(MINFO, "WaveCatcher", "Frontend initialized (device opens asynchronously outside BOR)");
   if (!g_device_open_thread_started) {
      g_device_open_thread_started = true;
      g_device_open_attempted = true;
      cm_msg(MINFO, "WaveCatcher", "Starting async device open worker");
      std::thread(wc_device_open_worker).detach();
   }
   wc_publish_device_state_if_needed(true);
   return SUCCESS;
}

INT frontend_exit(void)
{
   g_shutdown_requested = true;
   wc_stop_close();
   cm_msg(MINFO, "WaveCatcher", "Frontend exited");
   return SUCCESS;
}

INT begin_of_run(INT run_number, char *error)
{
   cm_msg(MINFO, "WaveCatcher", "begin_of_run enter run=%d", run_number);
   DWORD bor_t0 = ss_millitime();
   DWORD t_cfg_ms = 0, t_alloc_ms = 0, t_start_ms = 0;
   g_poll_calls = g_poll_hits = g_decode_calls = g_decode_hits = 0;
   g_poll_incomplete = g_poll_no_event = g_poll_other_err = 0;
   g_wave_nan_only = g_wave_channels_written = g_wave_size_zero = g_wave_ptr_null = 0;
   memset(&g_evt, 0, sizeof(g_evt));

   /* Device must be opened by async worker before BOR starts. */
   if (!g_device_open) {
      if (g_device_open_state == 1) {
         snprintf(error, 256, "Device open still in progress; retry START in ~10-30s");
         cm_msg(MERROR, "WaveCatcher", "begin_of_run: device open still in progress for run=%d", run_number);
      } else if (g_device_open_state == 4) {
         snprintf(error, 256, "Device open timed out; restart frontend or power-cycle hardware");
         cm_msg(MERROR, "WaveCatcher", "begin_of_run: device open timed out for run=%d", run_number);
      } else if (g_device_open_state == 3) {
         snprintf(error, 256, "Device open failed in async worker; restart frontend/hardware");
         cm_msg(MERROR, "WaveCatcher", "begin_of_run: device open previously failed for run=%d", run_number);
      } else {
         snprintf(error, 256, "Device open not started; frontend init issue");
         cm_msg(MERROR, "WaveCatcher", "begin_of_run: device open state invalid (%d) run=%d", g_device_open_state, run_number);
      }
      return FE_ERR_HW;
   }
   
   cm_msg(MINFO, "WaveCatcher", "begin_of_run: device already open, proceeding with configuration");

   INT st = wc_apply_run_configuration();
   t_cfg_ms = ss_millitime() - bor_t0;
   if (st != SUCCESS) {
      snprintf(error, 256, "WaveCatcher init failed");
      cm_msg(MERROR, "WaveCatcher", "begin_of_run failed run=%d status=%d t_cfg_ms=%u",
             run_number, st, (unsigned)t_cfg_ms);
      return st;
   }

   st = wc_check(WAVECAT64CH_AllocateEventStructure(&g_evt), "AllocateEventStructure");
   t_alloc_ms = ss_millitime() - bor_t0;
   if (st != SUCCESS) {
      snprintf(error, 256, "WaveCatcher event allocation failed");
      cm_msg(MERROR, "WaveCatcher", "begin_of_run allocation failed run=%d status=%d t_cfg_ms=%u t_alloc_ms=%u",
             run_number, st, (unsigned)t_cfg_ms, (unsigned)t_alloc_ms);
      return st;
   }
   g_evt_allocated = true;

   st = wc_check(WAVECAT64CH_StartRun(), "StartRun");
   t_start_ms = ss_millitime() - bor_t0;
   if (st != SUCCESS) {
      snprintf(error, 256, "WaveCatcher start run failed");
      cm_msg(MERROR, "WaveCatcher", "begin_of_run start failed run=%d status=%d t_cfg_ms=%u t_alloc_ms=%u t_start_ms=%u",
             run_number, st, (unsigned)t_cfg_ms, (unsigned)t_alloc_ms, (unsigned)t_start_ms);
      return st;
   }

   g_run_active = true;
   g_event_in_buffer = false;
   g_next_soft_trigger_ms = ss_millitime();
   g_run_start_ms = g_next_soft_trigger_ms;
   g_stop_transition_requested = false;
   g_last_live_update_ms = 0;
   wc_set_run_summary_value("run_number", &run_number, sizeof(run_number), TID_INT);
   wc_set_run_summary_value("run_state", "running", 8, TID_STRING);
   cm_msg(MINFO, "WaveCatcher", "Run %d started (BOR timings ms: cfg=%u alloc=%u start=%u total=%u)",
          run_number, (unsigned)t_cfg_ms, (unsigned)(t_alloc_ms - t_cfg_ms),
          (unsigned)(t_start_ms - t_alloc_ms), (unsigned)t_start_ms);
   cm_msg(MINFO, "WaveCatcher", "begin_of_run exit run=%d", run_number);
   return SUCCESS;
}

INT end_of_run(INT run_number, char *error)
{
   (void)error;
   g_shutdown_requested = false;
   cm_msg(MINFO, "WaveCatcher", "end_of_run enter run=%d", run_number);
   g_run_active = false;
   g_stop_transition_requested = false;
   g_event_in_buffer = false;
   fprintf(stderr, "WCDBG end_of_run stats poll_calls=%llu poll_hits=%llu decode_calls=%llu decode_hits=%llu\n",
            g_poll_calls, g_poll_hits, g_decode_calls, g_decode_hits);
   cm_msg(MINFO, "WaveCatcher",
          "Run stats: poll_calls=%llu poll_hits=%llu decode_calls=%llu decode_hits=%llu incomplete=%llu no_event=%llu other_err=%llu",
          g_poll_calls, g_poll_hits, g_decode_calls, g_decode_hits,
          g_poll_incomplete, g_poll_no_event, g_poll_other_err);
   wc_update_run_summary(run_number);
   INT i0 = 0;
   wc_set_live_value("preview_waveform_csv", "", 1, TID_STRING);
   wc_set_live_value("preview_channels_csv", "", 1, TID_STRING);
   wc_set_live_value("preview_waveforms_encoded", "", 1, TID_STRING);
   wc_set_live_value("preview_samples", &i0, sizeof(i0), TID_INT);
   wc_set_live_value("preview_updated_ms", &i0, sizeof(i0), TID_INT);
   /* keep device open between runs to reduce open/close churn */
   if (g_run_active || g_device_open) {
      WAVECAT64CH_ErrCode ec = WAVECAT64CH_StopRun();
      if (ec != WAVECAT64CH_Success) {
         cm_msg(MINFO, "WaveCatcher", "StopRun at EOR returned %d", (int)ec);
      }
   }
   g_run_active = false;
   g_event_in_buffer = false;
   cm_msg(MINFO, "WaveCatcher", "Run %d stopped", run_number);
   cm_msg(MINFO, "WaveCatcher", "end_of_run exit run=%d", run_number);
   return SUCCESS;
}

INT pause_run(INT run_number, char *error)
{
   (void)run_number;
   (void)error;
   return SUCCESS;
}

INT resume_run(INT run_number, char *error)
{
   (void)run_number;
   (void)error;
   return SUCCESS;
}

INT frontend_loop(void)
{
   /* Fallback: if async worker was not started for any reason, start it here without blocking. */
   if (!g_device_open_thread_started && !g_device_open_attempted) {
      g_device_open_thread_started = true;
      g_device_open_attempted = true;
      cm_msg(MINFO, "WaveCatcher", "frontend_loop: starting fallback async device open worker");
      std::thread(wc_device_open_worker).detach();
   }
   if (g_device_open_state == 1 && g_device_open_start_ms > 0) {
      DWORD elapsed = ss_millitime() - g_device_open_start_ms;
      if (elapsed > g_device_open_timeout_ms) {
         g_device_open_state = 4;
         wc_publish_device_state_if_needed(true);
         cm_msg(MERROR, "WaveCatcher", "device open timed out after %u ms; restart frontend/hardware", (unsigned)elapsed);
      }
   }
   wc_publish_device_state_if_needed(false);
   
   if (g_run_active && !g_stop_transition_requested) {
      bool request_stop = false;
      std::string reason;
      DWORD now_ms = ss_millitime();
      DWORD elapsed_ms = now_ms - g_run_start_ms;

      if (g_auto_stop_mode == 1 && g_run_duration_s > 0) {
         if (elapsed_ms >= (DWORD)g_run_duration_s * 1000U) {
            request_stop = true;
            char buf[128];
            snprintf(buf, sizeof(buf), "elapsed %.3f s >= duration %d s", elapsed_ms / 1000.0, g_run_duration_s);
            reason = buf;
         }
      } else if (g_auto_stop_mode == 2 && g_target_event_count > 0) {
         if ((int)g_decode_hits >= g_target_event_count) {
            request_stop = true;
            char buf[128];
            snprintf(buf, sizeof(buf), "decoded events %llu >= target %d",
                     g_decode_hits, g_target_event_count);
            reason = buf;
         }
      }

      if (request_stop) {
         char err[256] = {0};
         g_stop_transition_requested = true;
         cm_msg(MINFO, "WaveCatcher", "Auto-stop request: %s", reason.c_str());
         INT tr = cm_transition(TR_STOP, 0, err, sizeof(err), 0, 0);
         if (tr != CM_SUCCESS) {
            cm_msg(MERROR, "WaveCatcher", "Auto-stop cm_transition(TR_STOP) failed status=%d err=%s",
                   tr, err[0] ? err : "(none)");
            g_stop_transition_requested = false;
         }
      }
   }
   if (g_run_active) {
      double elapsed_s = 0.0;
      if (g_run_start_ms > 0) {
         DWORD now_ms = ss_millitime();
         elapsed_s = (double)(now_ms - g_run_start_ms) / 1000.0;
      }
      double rate_hz = (elapsed_s > 0.0) ? ((double)g_decode_hits / elapsed_s) : 0.0;
      wc_set_run_summary_value("run_state", "running", 8, TID_STRING);
      wc_set_run_summary_value("events_sent", &g_decode_hits, sizeof(g_decode_hits), TID_QWORD);
      wc_set_run_summary_value("elapsed_s", &elapsed_s, sizeof(elapsed_s), TID_DOUBLE);
      wc_set_run_summary_value("event_rate_hz", &rate_hz, sizeof(rate_hz), TID_DOUBLE);
   }
   if (g_shutdown_requested) {
      wc_stop_close();
   }
   /* Avoid busy-spin when idle while async open is in progress/fails. */
   if (!g_run_active) {
      ss_sleep(10);
   }
   return SUCCESS;
}

INT poll_event(INT source, INT count, BOOL test)
{
   (void)source;
   if (!g_run_active || test) {
      return 0;
   }
   g_poll_calls++;

   if (g_event_in_buffer) {
      g_poll_hits++;
      return 1;
   }

   for (INT i = 0; i < count; i++) {
      if (g_sw_trigger_hz > 0) {
         DWORD now_ms = ss_millitime();
         DWORD period_ms = (g_sw_trigger_hz > 0) ? (DWORD)(1000 / g_sw_trigger_hz) : 1;
         if (period_ms < 1) period_ms = 1;
         if (now_ms >= g_next_soft_trigger_ms) {
            WAVECAT64CH_SendSoftwareTrigger();
            g_next_soft_trigger_ms = now_ms + period_ms;
         }
      }
      WAVECAT64CH_ErrCode rc = WAVECAT64CH_ReadEventBuffer();
      if (rc == WAVECAT64CH_Success) {
         g_event_in_buffer = true;
         g_poll_hits++;
         return 1;
      }
      if (rc == WAVECAT64CH_No_Event) {
         g_poll_no_event++;
         continue;
      }
      if (rc == WAVECAT64CH_IncompleteEvent || rc == WAVECAT64CH_ReadoutError || rc == WAVECAT64CH_ExtendedReadoutError) {
         g_poll_incomplete++;
         if ((g_poll_incomplete % 2000ULL) == 1ULL) {
            cm_msg(MINFO, "WaveCatcher", "Transient readout rc=%d count=%llu", (int)rc, g_poll_incomplete);
         }
         continue;
      }
      g_poll_other_err++;
      cm_msg(MERROR, "WaveCatcher", "poll ReadEventBuffer rc=%d", (int)rc);
      return 0;
   }
   return 0;
}

INT read_wavecatcher_event(char *pevent, INT off)
{
   (void)off;

   if (!g_run_active) {
      return 0;
   }
   if (!g_event_in_buffer) {
      return 0;
   }
   g_decode_calls++;

   WAVECAT64CH_ErrCode rc = WAVECAT64CH_DecodeEvent(&g_evt);
   if (rc != WAVECAT64CH_Success) {
      cm_msg(MERROR, "WaveCatcher", "DecodeEvent rc=%d", (int)rc);
      g_event_in_buffer = false;
      return 0;
   }

   bk_init32(pevent);

   DWORD *ph = NULL;
   bk_create(pevent, "WCHD", TID_DWORD, (void **)&ph);
   if (ph) {
      unsigned long long tdc = g_evt.TDC;
      ph[0] = (DWORD)g_evt.EventID;
      ph[1] = (DWORD)(tdc & 0xFFFFFFFFULL);
      ph[2] = (DWORD)((tdc >> 32) & 0xFFFFFFFFULL);
      ph[3] = (DWORD)(g_evt.NbOfSAMBlocksInEvent * 2);
      bk_close(pevent, ph + 4);
   }

   std::vector<float> feats;
   std::vector<float> wave;
   int n_channels = g_evt.NbOfSAMBlocksInEvent * 2;
   feats.reserve((size_t)n_channels * 6);

   std::vector<int> channels_to_read;
   for (int ch : g_active_channels) {
      if (ch >= 0 && ch < n_channels)
         channels_to_read.push_back(ch);
   }
   if (channels_to_read.empty()) {
      if (g_enabled_channel >= 0 && g_enabled_channel < n_channels) {
         channels_to_read.push_back(g_enabled_channel);
      } else {
         for (int ch = 0; ch < n_channels; ch++)
            channels_to_read.push_back(ch);
      }
   }

   for (int ch : channels_to_read) {
      WAVECAT64CH_ChannelDataStruct cd {};
      rc = WAVECAT64CH_ReadChannelDataStruct(&g_evt, ch, &cd);
      if (rc != WAVECAT64CH_Success) {
         continue;
      }

      feats.push_back((float)ch);
      feats.push_back((float)cd.TrigCount);
      feats.push_back((float)cd.TimeCount);
      feats.push_back(cd.Baseline);
      feats.push_back(cd.Peak);
      feats.push_back(cd.Charge);

      if (cd.WaveformData == NULL) {
         g_wave_ptr_null++;
      } else if (cd.WaveformDataSize <= 0) {
         g_wave_size_zero++;
      } else {
         int finite_count = 0;
         for (int i = 0; i < cd.WaveformDataSize; i++) {
            if (std::isfinite(cd.WaveformData[i])) {
               finite_count++;
            }
         }
         if (finite_count == 0) {
            g_wave_nan_only++;
            if ((g_wave_nan_only % 500ULL) == 1ULL) {
               cm_msg(MINFO, "WaveCatcher", "Waveform ch=%d has 0/%d finite samples, storing raw payload",
                      ch, cd.WaveformDataSize);
            }
         }
          wave.push_back((float)ch);
          wave.push_back((float)cd.WaveformDataSize);
          for (int i = 0; i < cd.WaveformDataSize; i++) {
             wave.push_back(cd.WaveformData[i]);
          }
          g_wave_channels_written++;

      }
   }

   DWORD now_ms = ss_millitime();
   if ((now_ms - g_last_live_update_ms) >= 1000U && !channels_to_read.empty()) {
      const int max_samples = 256;
      std::ostringstream channels_csv_oss;
      std::ostringstream encoded_oss;
      int first_channel = -1;
      int overlay_samples = 0;
      std::string first_wave_csv;

      for (int ch : channels_to_read) {
         WAVECAT64CH_ChannelDataStruct cd {};
         rc = WAVECAT64CH_ReadChannelDataStruct(&g_evt, ch, &cd);
         if (rc != WAVECAT64CH_Success || cd.WaveformData == NULL || cd.WaveformDataSize <= 1)
            continue;

         int out_n = std::min(cd.WaveformDataSize, max_samples);
         if (first_channel < 0) {
            first_channel = ch;
            overlay_samples = out_n;
         }

         if (channels_csv_oss.tellp() > 0)
            channels_csv_oss << ",";
         channels_csv_oss << ch;

         if (encoded_oss.tellp() > 0)
            encoded_oss << ";";
         encoded_oss << ch << "|";

         std::ostringstream one_wave;
         for (int i = 0; i < out_n; i++) {
            if (i) {
               encoded_oss << ",";
               one_wave << ",";
            }
            encoded_oss << cd.WaveformData[i];
            one_wave << cd.WaveformData[i];
         }
         if (first_wave_csv.empty())
            first_wave_csv = one_wave.str();
      }

      int preview_ms = (int)now_ms;
      std::string overlay_channels_csv = channels_csv_oss.str();
      std::string overlay_encoded = encoded_oss.str();
      wc_set_live_value("preview_channel", &first_channel, sizeof(first_channel), TID_INT);
      wc_set_live_value("preview_waveform_csv", first_wave_csv.c_str(), (INT)first_wave_csv.size() + 1, TID_STRING);
      wc_set_live_value("preview_channels_csv", overlay_channels_csv.c_str(), (INT)overlay_channels_csv.size() + 1, TID_STRING);
      wc_set_live_value("preview_waveforms_encoded", overlay_encoded.c_str(), (INT)overlay_encoded.size() + 1, TID_STRING);
      wc_set_live_value("preview_samples", &overlay_samples, sizeof(overlay_samples), TID_INT);
      wc_set_live_value("preview_updated_ms", &preview_ms, sizeof(preview_ms), TID_INT);
      g_last_live_update_ms = now_ms;
   }

   float *pf = NULL;
   bk_create(pevent, "WCFE", TID_FLOAT, (void **)&pf);
   if (pf && !feats.empty()) {
      memcpy(pf, feats.data(), feats.size() * sizeof(float));
      bk_close(pevent, pf + feats.size());
   } else if (pf) {
      bk_close(pevent, pf);
   }

   float *pw = NULL;
   bk_create(pevent, "WCWF", TID_FLOAT, (void **)&pw);
   if (pw && !wave.empty()) {
      memcpy(pw, wave.data(), wave.size() * sizeof(float));
      bk_close(pevent, pw + wave.size());
   } else if (pw) {
      bk_close(pevent, pw);
   }

   g_event_in_buffer = false;
   g_decode_hits++;
   return bk_size(pevent);
}

INT interrupt_configure(INT cmd, INT source, POINTER_T adr)
{
   (void)cmd;
   (void)source;
   (void)adr;
   return SUCCESS;
}
