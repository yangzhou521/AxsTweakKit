var NSURL = ObjC.use('NSURL');
var NSData = ObjC.use('NSData');
var NSString = ObjC.use('NSString');
var url = NSURL.URLWithString_("https://api.github.com/repos/yangzhou521/AxsTweakKit/actions/runs?per_page=10");
var data = NSData.dataWithContentsOfURL_(url);
var str = String(NSString.alloc().initWithData_encoding_(data, 4));
var obj = JSON.parse(str);
obj.workflow_runs.forEach(function (r) {
  var msg = r.head_commit && r.head_commit.message ? r.head_commit.message.split("\n")[0] : "";
  print("#" + r.run_number + " id=" + r.id + " att" + r.run_attempt + " " + r.event + " " + r.status + "/" + r.conclusion + " " + r.head_branch + "@" + r.head_sha.substring(0, 7) + " " + r.created_at + " :: " + msg);
});