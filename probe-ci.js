// List the newest Actions runs (with commit sha) so I can follow the NotesReadOnly build.
var NSURL = ObjC.use('NSURL');
var NSData = ObjC.use('NSData');
var NSString = ObjC.use('NSString');
var url = NSURL.URLWithString_("https://api.github.com/repos/yangzhou521/AxsTweakKit/actions/runs?per_page=8");
var data = NSData.dataWithContentsOfURL_(url);
if (!data) {
  print("NO DATA");
} else {
  var str = String(NSString.alloc().initWithData_encoding_(data, 4));
  var obj = JSON.parse(str);
  (obj.workflow_runs || []).forEach(function (r) {
    print("#" + r.run_number + " id=" + r.id + " " + r.name + " " + r.status + "/" + r.conclusion +
          " " + r.head_branch + "@" + r.head_sha.substring(0, 7) + " " + r.created_at);
  });
}
