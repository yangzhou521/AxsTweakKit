// Show the raw HTTP status/body for an API call, to tell rate limiting from a network error.
var NSURL = ObjC.use('NSURL');
var NSData = ObjC.use('NSData');
var NSString = ObjC.use('NSString');
var NSHTTPURLResponse = ObjC.use('NSHTTPURLResponse');
var NSMutableURLRequest = ObjC.use('NSMutableURLRequest');

var req = NSMutableURLRequest.requestWithURL_(NSURL.URLWithString_("https://api.github.com/repos/yangzhou521/AxsTweakKit/actions/runs?per_page=5"));
req.setValue_forHTTPHeaderField_("Apelin-CI", "User-Agent");
var resp = ObjC.alloc("NSURLResponse");
var err = ObjC.alloc("NSError");
var data = NSURL.connectionSendSynchronousRequest_returningResponse_error_(req, resp, err);
print("data? " + (data ? "yes len=" + data.length() : "no") + " err=" + (err ? err.description() : "none"));
if (data) {
  print("status raw: " + resp.description());
  print(String(NSString.alloc().initWithData_encoding_(data, 4)).substring(0, 400));
}
