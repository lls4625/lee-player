// Production-method asynchronous acknowledgement contracts.
// Fake transport and virtual scheduler; this does not exercise Apple SDKs.

final class Wire {
 struct Call { let method:String; let args:[String:Any]; let completion:(Bool)->Void }
 var calls:[Call]=[]
 func send(_ method:String,_ args:[String:Any],_ done:@escaping (Bool)->Void) { calls.append(Call(method:method,args:args,completion:done)) }
 var methods:[String] { calls.map(\.method) }
 func reply(_ index:Int,_ success:Bool) { calls[index].completion(success); DispatchQueue.main.advance() }
}
func wired()->(Service,Wire) {
 let s=fresh(), w=Wire();s.mediaKit=LeeMediaKitEngine(transport:w.send)
 s.mediaKit?.update(["positionVersion":0,"snapshotSequence":1,"ready":true,"duration":120.0,"seekable":true,"position":0.0])
 return (s,w)
}
do {
 let (s,w)=wired();s.play();w.reply(0,false)
 check(w.methods == ["play","pause"] && s.audioRecoveryPending,"current play rejection pauses and schedules recovery")
 DispatchQueue.main.advance(0.25)
 check(w.methods == ["play","pause","play"],"current rejection retry fires at configured policy interval")
}
do {
 let (s,w)=wired();s.play();s.pause();w.reply(0,false)
 check(w.methods == ["play","pause"] && !s.audioRecoveryPending,"pause-only protects against old rejected play")
}
do {
 let (s,w)=wired();s.play();s.pause();s.play()
 print("TRACE before old rejected Play: \(w.methods)")
 w.reply(0,false)
 print("TRACE after old rejected Play: \(w.methods), pending=\(s.audioRecoveryPending), attempt=\(s.audioRecoveryAttempt)")
 check(w.methods == ["play","pause","play"] && !s.audioRecoveryPending,"older rejected Play must not insert Pause after latest Play")
}
do {
 let (s,w)=wired();s.play();w.calls[0].completion(true);s.pause();AVAudioSession.instance.activationFailures=1;s.play()
 check(s.audioRecoveryPending && s.audioRecoveryWorkItem != nil,"new Play activation failure has a pending authorized retry")
 DispatchQueue.main.advance()
 print("TRACE old successful Play against newer activation failure: pending=\(s.audioRecoveryPending), work=\(s.audioRecoveryWorkItem != nil)")
 check(s.audioRecoveryPending && s.audioRecoveryWorkItem != nil,"older successful Play must not cancel newer activation retry")
}
do {
 let (s,w)=wired();s.play();s.seek(20)
 w.reply(0,false)
 check(w.methods == ["play","pause","seek"] && !s.audioRecoveryPending,"older rejected Play must not add recovery commands during newer seek")
}
do {
 let (s,w)=wired();s.play();s.generation += 1;w.reply(0,false)
 check(w.methods == ["play"] && !s.audioRecoveryPending,"session generation fence discards old rejection")
}

do {
 let (s,w)=wired();s.play();s.pause();s.seek(30);s.play()
 check(w.methods == ["play","pause","pause","seek"] && s.wantsPlayback && s.isSeeking,"quick Pause-Seek-Play waits for the new seek")
 w.reply(0,false)
 check(w.methods == ["play","pause","pause","seek"],"old rejected Play does not inject Pause into newer Pause-Seek-Play")
 s.mediaKit?.update(["positionVersion":1,"snapshotSequence":2,"position":30.0])
 w.reply(3,true)
 check(w.methods.last == "play" && !s.isSeeking && s.initialPositionEstablished,"seek confirmation resumes the newest Play intent")
}
for success in [false,true] {
 let (s,w)=wired();s.play();s.environmentAllowed=false;s.enforcePlaybackEnvironment()
 let before=w.methods;w.reply(0,success)
 check(w.methods == before && !s.audioRecoveryPending && !s.wantsPlayback,"background-disabled policy rejects old completion success=\(success)")
}
for success in [false,true] {
 let (s,w)=wired();s.play();s.generation += 1;s.currentPath="b.mkv"
 let next=Wire();s.mediaKit=LeeMediaKitEngine(transport:next.send)
 w.reply(0,success)
 check(next.methods.isEmpty && !s.audioRecoveryPending,"new media generation rejects old completion success=\(success)")
}
do {
 let (s,w)=wired();s.play();s.playbackOperation += 1
 let next=Wire();s.mediaKit=LeeMediaKitEngine(transport:next.send)
 w.reply(0,false)
 check(next.methods.isEmpty && !s.audioRecoveryPending,"same-path replacement engine rejects prior engine completion")
}


do {
 let s=fresh();s.play();s.pause();AVAudioSession.instance.activationFailures=1;s.play()
 check(s.audioRecoveryPending && s.audioRecoveryWorkItem != nil,"AV new Play activation failure has an authorized retry")
 DispatchQueue.main.advance()
 check(s.audioRecoveryPending && s.audioRecoveryWorkItem != nil,"AV old synchronous success queued on main must not cancel newer activation retry")
}


do {
 let (s,w)=wired();s.play();w.reply(0,false);DispatchQueue.main.advance(0.25);w.reply(2,true)
 check(w.methods == ["play","pause","play"] && !s.audioRecoveryPending && s.audioRecoveryWorkItem == nil && !s.audioRecoveryExhausted && s.audioRecoveryAttempt == 0,
       "current successful MK retry still clears recovery")
}
do {
 let s=fresh();AVAudioSession.instance.activationFailures=1;s.play();DispatchQueue.main.advance(0.25)
 check(!s.audioRecoveryPending && s.audioRecoveryWorkItem == nil && !s.audioRecoveryExhausted && s.audioRecoveryAttempt == 0 && AVAudioSession.instance.activations == 2,
       "current successful AV retry still clears recovery")
}


// Positive controls: the fence must still accept the newest acknowledgement.
do {
 let (s,w)=wired();s.play();s.pause();s.play();w.reply(2,true)
 check(s.audioRecoveryRequest == nil && !s.audioRecoveryPending && s.wantsPlayback,
       "latest MK Play success completes its own recovery")
 let count=w.calls.count;w.reply(0,false)
 check(w.calls.count == count && !s.audioRecoveryPending,
       "old rejection after latest success cannot restart recovery")
}
do {
 let (s,w)=wired();s.play();s.play();w.reply(0,false)
 check(w.methods == ["play","play"], "a newer Play request supersedes older Play without requiring Pause")
 w.reply(1,false)
 check(w.methods == ["play","play","pause"] && s.audioRecoveryPending,
       "latest Play rejection still schedules legitimate recovery")
 DispatchQueue.main.advance(0.25);w.reply(3,true)
 check(s.audioRecoveryRequest == nil && !s.audioRecoveryPending && s.audioRecoveryAttempt==0,
       "successful current retry consumes its request and resets budget")
}
do {
 let s=fresh();s.play();DispatchQueue.main.advance()
 check(s.audioRecoveryRequest == nil && !s.audioRecoveryPending && s.wantsPlayback,
       "current AVPlayer queued success completes its own recovery")
}
do {
 let (s,w)=wired();s.play();s.pauseEngine();let count=w.calls.count;w.reply(0,false)
 check(w.calls.count==count && !s.audioRecoveryPending,
       "direct engine pause invalidates old MK Play without changing service intent")
}
do {
 let (s,w)=wired();s.play();w.reply(0,true);let count=w.calls.count;w.reply(0,false)
 check(w.calls.count==count && !s.audioRecoveryPending,
       "already consumed request cannot mutate recovery on a duplicate acknowledgement")
}

print("RESULT \(tests-failures)/\(tests) passed; \(failures) failures; exact app method bodies, fake transport and virtual scheduler, no Apple SDK")
exit(failures==0 ? 0:1)
