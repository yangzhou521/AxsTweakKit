// Save the published 1.0.8 deb to a real path so irisin-cli (root) can install it.
// 写到 /var/mobile/Documents（mobile 可写、root 可读），不要写 /tmp：
// icli 走真实路径，而 bootstrap shell 眼里的 /tmp 是 jbroot 里的另一处。
var NSURL = ObjC.use('NSURL');
var NSData = ObjC.use('NSData');

var asset = "https://github.com/yangzhou521/AxsTweakKit/releases/download/notesreadonly-v1.0.8/com.unknown.notesreadonly_1.0.8_iphoneos-arm64e.deb";
var data = NSData.dataWithContentsOfURL_(NSURL.URLWithString_(asset));
if (!data) {
  print("NO DATA");
} else {
  var path = "/var/mobile/Documents/notesreadonly_1.0.8_iphoneos-arm64e.deb";
  var ok = data.writeToFile_atomically_(path, true);
  print("wrote " + path + " ok=" + ok + " len=" + data.length());
}
