// One-shot report on the newest "Build NotesReadOnly" run: run/job/step status plus
// every check-run annotation (annotations are public; the job log is not).
var NSURL = ObjC.use('NSURL');
var NSData = ObjC.use('NSData');
var NSString = ObjC.use('NSString');

function getJSON(url) {
  var data = NSData.dataWithContentsOfURL_(NSURL.URLWithString_(url));
  if (!data) { return null; }
  return JSON.parse(String(NSString.alloc().initWithData_encoding_(data, 4)));
}

var REPO = "yangzhou521/AxsTweakKit";
var runs = getJSON("https://api.github.com/repos/" + REPO + "/actions/runs?per_page=10");
if (!runs) { print("NO DATA (runs)"); } else {
  var run = null;
  (runs.workflow_runs || []).forEach(function (r) {
    if (!run && r.name === "Build NotesReadOnly") { run = r; }
  });
  if (!run) { print("no NotesReadOnly run yet"); } else {
    print("run #" + run.run_number + " id=" + run.id + " " + run.status + "/" + run.conclusion +
          " sha=" + run.head_sha.substring(0, 7) + " " + run.created_at);
    var jobs = getJSON("https://api.github.com/repos/" + REPO + "/actions/runs/" + run.id + "/jobs");
    ((jobs && jobs.jobs) || []).forEach(function (j) {
      print("job " + j.name + " " + j.status + "/" + j.conclusion);
      (j.steps || []).forEach(function (s) {
        if (s.conclusion !== "success" || /Build|Verify/.test(s.name)) {
          print("   step " + s.number + " " + s.name + " " + s.status + "/" + s.conclusion);
        }
      });
    });
    var cr = getJSON("https://api.github.com/repos/" + REPO + "/commits/" + run.head_sha + "/check-runs");
    ((cr && cr.check_runs) || []).forEach(function (c) {
      if (c.conclusion === "success" && c.name !== "Build (roothide)") { return; }
      print("check " + c.name + " " + c.conclusion);
      var an = getJSON(c.url + "/annotations");
      (an || []).forEach(function (a) {
        if (a.message && a.message.indexOf("Node.js 20") >= 0) { return; }
        print("   [" + a.annotation_level + "][" + (a.title || "") + "] " + (a.message || ""));
      });
    });
  }
}
