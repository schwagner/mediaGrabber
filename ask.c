/* ============================================================
 * ask.c — mediagrab-ask: a desktop notification that asks a question
 *
 * Usage: mediagrab-ask [--title T] [--reply PLACEHOLDER] [--while CMD]
 *                      MESSAGE KEY=LABEL...
 *
 * One button per KEY=LABEL; prints the KEY of the button pressed. --reply
 * adds a text field (the KDE inline-reply extension: noctalia, KDE, ...),
 * and what is typed there is printed as "reply TEXT". --while CMD keeps the
 * question up only while `sh -c CMD` succeeds, checked every 5 s. Exits 1,
 * printing nothing, when the question is dismissed, withdrawn, or cannot be
 * asked (no session bus, no notification server).
 *
 * WHY C. Servers may send ActionInvoked/NotificationReplied only to the
 * connection that called Notify (noctalia does), and drop them once that
 * connection is gone. notify-send keeps it open but cannot take a reply;
 * gdbus and busctl cannot keep it open. sd-bus is in libsystemd, which is
 * on every NixOS host already.
 * ============================================================ */
#include <getopt.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <systemd/sd-bus.h>

#define NF_NAME "org.freedesktop.Notifications"
#define NF_PATH "/org/freedesktop/Notifications"

static uint32_t id;
static int done;         /* 1 answered, -1 closed */
static char *answer;

static int on_signal(sd_bus_message *m, void *u, sd_bus_error *e) {
  (void)u; (void)e;
  const char *member = sd_bus_message_get_member(m), *s = NULL;
  uint32_t nid;
  if (!member || sd_bus_message_read(m, "u", &nid) < 0 || nid != id) return 0;
  if (!strcmp(member, "NotificationClosed")) {
    if (!done) done = -1;
  } else if (!strcmp(member, "ActionInvoked")) {
    if (sd_bus_message_read(m, "s", &s) < 0 || !strcmp(s, "inline-reply")) return 0;
    answer = strdup(s); done = 1;
  } else if (!strcmp(member, "NotificationReplied")) {
    if (sd_bus_message_read(m, "s", &s) < 0) return 0;
    if (!*s) { done = -1; return 0; }
    if (asprintf(&answer, "reply %s", s) < 0) return -1;
    done = 1;
  }
  return 0;
}

int main(int argc, char **argv) {
  const char *title = "Disc needs a decision", *reply = NULL, *cond = NULL;
  static struct option opts[] = {
    {"title", required_argument, 0, 't'}, {"reply", required_argument, 0, 'r'},
    {"while", required_argument, 0, 'w'}, {0, 0, 0, 0}};
  for (int c; (c = getopt_long(argc, argv, "+t:r:w:", opts, NULL)) != -1;) {
    if (c == 't') title = optarg;
    else if (c == 'r') reply = optarg;
    else if (c == 'w') cond = optarg;
    else return 2;
  }
  if (optind >= argc) {
    fprintf(stderr, "usage: mediagrab-ask [--title T] [--reply P] [--while CMD] MESSAGE KEY=LABEL...\n");
    return 2;
  }
  const char *body = argv[optind++];

  sd_bus *bus = NULL;
  sd_bus_message *m = NULL, *r = NULL;
  sd_bus_error err = SD_BUS_ERROR_NULL;
  if (sd_bus_open_user(&bus) < 0) return 1;
  if (sd_bus_match_signal(bus, NULL, NF_NAME, NF_PATH, NF_NAME, NULL, on_signal, NULL) < 0) return 1;

  /* Notify(app, replaces, icon, summary, body, actions, hints, timeout) */
  if (sd_bus_message_new_method_call(bus, &m, NF_NAME, NF_PATH, NF_NAME, "Notify") < 0 ||
      sd_bus_message_append(m, "susss", "mediagrab", 0, "dialog-question", title, body) < 0 ||
      sd_bus_message_open_container(m, 'a', "s") < 0) return 1;
  for (int i = optind; i < argc; i++) {
    char *eq = strchr(argv[i], '=');
    if (!eq) { fprintf(stderr, "not KEY=LABEL: %s\n", argv[i]); return 2; }
    *eq = 0;
    sd_bus_message_append(m, "ss", argv[i], eq + 1);
  }
  if (reply) sd_bus_message_append(m, "ss", "inline-reply", "Reply");
  sd_bus_message_close_container(m);
  sd_bus_message_open_container(m, 'a', "{sv}");
  sd_bus_message_append(m, "{sv}", "urgency", "y", (uint8_t)2);
  sd_bus_message_append(m, "{sv}", "resident", "b", 1);
  if (reply) sd_bus_message_append(m, "{sv}", "x-kde-reply-placeholder-text", "s", reply);
  sd_bus_message_close_container(m);
  if (sd_bus_message_append(m, "i", 0) < 0) return 1;
  if (sd_bus_call(bus, m, 0, &err, &r) < 0 || sd_bus_message_read(r, "u", &id) < 0) {
    fprintf(stderr, "Notify failed: %s\n", err.message ? err.message : "?");
    return 1;
  }

  while (!done) {
    int n = sd_bus_process(bus, NULL);
    if (n < 0) return 1;            /* bus gone (logged out) */
    if (n > 0) continue;
    if (sd_bus_wait(bus, 5 * 1000000ULL) == 0 && cond && system(cond) != 0) break;
  }
  if (done != -1)                   /* answered, or withdrawn: take it down */
    sd_bus_call_method(bus, NF_NAME, NF_PATH, NF_NAME, "CloseNotification", NULL, NULL, "u", id);
  if (done == 1) { puts(answer); return 0; }
  return 1;
}
