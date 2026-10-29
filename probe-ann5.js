// 读 NotesReadOnly run #5 (id=40861637149) 的 check-run 注解：job 日志要登录，注解匿名可读。
var NSURL = ObjC.use('NSURL');
var NSData = ObjC.use('NSData');
var NSString = ObjC.use('NSString');

function getJSON(url) {
  var data = NSData.dataWithContentsOfURL_(NSURL.URLWithString_(url));
  if (!data) { return null; }
  return JSON.parse(String(NSString.alloc().initWithData_encoding_(data, 4)));
}

var REPO = "yangzhou521/AxsTweakKit";
var RUN = "40861637149";
var r = getJSON("https://api.github.com/repos/" + REPO + "/actions/runs/" + RUN);
if (!r) { print("NO DATA (run)"); } else {
  var sha = r.head_sha;
  print("run #" + r.run_number + " sha=" + sha.substring(0, 7) + " " + r.status + "/" + r.conclusion + " event=" + r.event);
  var jobs = getJSON("https://api.github.com/repos/" + REPO + "/actions/runs/" + RUN + "/jobs");
  if (!jobs) { print("NO DATA (jobs)"); } else {
    (jobs.jobs || []).forEach(function (j) {
      print("job " + j.name + " " + j.status + "/" + j.conclusion + " id=" + j.id);
      (j.steps || []).forEach(function (s) { print("   step " + s.number + " " + s.name + " -> " + s.status + "/" + (s.conclusion || "-")); });
      var an = getJSON("https://api.github.com/repos/" + REPO + "/check-runs/" + j.id + "/annotations");
      ((an && an.length !== undefined) ? an : []).forEach(function (a) {
        print("   [" + a.annotation_level + "][" + (a.title || "") + "] " + (a.message || ""));
      });
    });
  }
}
