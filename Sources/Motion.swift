import AppKit
import CoreGraphics
import QuartzCore
import OSLog

let gptBundleID = "com.openai.codex"
private let letteringLog = Logger(subsystem:"io.github.andrew-max365.gpt-welcome-animation",category:"lettering")
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: alpha)
}
func gradient(_ values: [UInt32], _ locations: [CGFloat]) -> CGGradient {
    CGGradient(colorsSpace: cs, colors: values.map { color($0) } as CFArray, locations: locations)!
}
func clamp(_ x: CGFloat, _ lo: CGFloat = 0, _ hi: CGFloat = 1) -> CGFloat { min(hi, max(lo, x)) }
func progress(_ t: CGFloat, _ a: CGFloat, _ b: CGFloat) -> CGFloat { clamp((t - a) / (b - a)) }
func smooth(_ u: CGFloat) -> CGFloat { u * u * (3 - 2 * u) }
func pen(_ u: CGFloat) -> CGFloat { 0.84 * u + 0.16 * smooth(u) }
func velocityRamp(_ u:CGFloat, initial:CGFloat, final:CGFloat, a:CGFloat=0.065, b:CGFloat=0.05)->CGFloat {
    let startDeficit=(1-initial)*(u<a ? u-u*u/(2*a) : a/2)
    let tail=max(0,u-(1-b)),endDeficit=(1-final)*tail*tail/(2*b)
    return clamp((u-startDeficit-endDeficit)/(1-(1-initial)*a/2-(1-final)*b/2))
}
enum MotionTiming {
    static let writeStart:CGFloat=0.22, writeEnd:CGFloat=5.72, bridgeEnd:CGFloat=6.74, logoEnd:CGFloat=7.98, portalStart:CGFloat=8.26, portalEnd:CGFloat=9.27, finish:CGFloat=9.35
}
func mix(_ a: CGFloat, _ b: CGFloat, _ u: CGFloat) -> CGFloat { a + (b - a) * u }
func dist(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(b.x - a.x, b.y - a.y) }

struct TracedPath {
    let points: [CGPoint]
    let cumulative: [CGFloat]
    var length: CGFloat { cumulative.last ?? 0 }
    init(_ points: [CGPoint]) {
        self.points = points
        var sums: [CGFloat] = [0]
        for i in 1..<points.count { sums.append(sums[i - 1] + dist(points[i - 1], points[i])) }
        self.cumulative = sums
    }
    func index(_ distance: CGFloat) -> Int {
        var a = 0, b = cumulative.count - 1
        while a + 1 < b { let m = (a+b)/2; if cumulative[m] <= distance { a = m } else { b = m } }
        return a
    }
    func point(_ distance: CGFloat) -> CGPoint {
        let d = clamp(distance, 0, length)
        if d >= length { return points.last! }
        let i = index(d), segment = cumulative[i + 1] - cumulative[i]
        let u = segment > 0 ? (d - cumulative[i])/segment : 0
        return CGPoint(x: mix(points[i].x, points[i+1].x, u), y: mix(points[i].y, points[i+1].y, u))
    }
    func part(_ start: CGFloat, _ end: CGFloat, close: Bool = false) -> CGPath {
        let path = CGMutablePath()
        let a = clamp(start, 0, length), b = clamp(end, 0, length)
        guard b > a + 0.01 else { return path }
        path.move(to: point(a))
        let lo = index(a)+1, hi = index(b)
        if lo <= hi { for i in lo...hi where cumulative[i] < b { path.addLine(to: points[i]) } }
        path.addLine(to: point(b)); if close { path.closeSubpath() }
        return path
    }
    static func cubic(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint, _ d: CGPoint) -> [CGPoint] {
        let n = max(8, Int(ceil((dist(a,b)+dist(b,c)+dist(c,d))/1.6)))
        return (1...n).map { i in
            let t = CGFloat(i)/CGFloat(n), u = 1-t
            return CGPoint(x: u*u*u*a.x + 3*u*u*t*b.x + 3*u*t*t*c.x + t*t*t*d.x,
                           y: u*u*u*a.y + 3*u*u*t*b.y + 3*u*t*t*c.y + t*t*t*d.y)
        }
    }
    static func parse(_ d: String) -> TracedPath? {
        let re = try! NSRegularExpression(pattern: "[MCLZ]|[-+]?(?:[0-9]*\\.[0-9]+|[0-9]+\\.?)")
        let tokens = re.matches(in: d, range: NSRange(d.startIndex...,in:d)).compactMap { Range($0.range,in:d).map { String(d[$0]) } }
        var points: [CGPoint] = [], i = 0, command = ""
        func xy(_ i: Int) -> CGPoint? {
            guard i + 1 < tokens.count, let x = Double(tokens[i]), let y = Double(tokens[i+1]) else { return nil }
            return CGPoint(x:x,y:y)
        }
        while i < tokens.count {
            if ["M","C","L","Z"].contains(tokens[i]) { command=tokens[i]; i+=1 }
            if command == "M", let p=xy(i) {points.append(p);i+=2;command="L"}
            else if command == "C", let a=points.last, let b=xy(i), let c=xy(i+2), let z=xy(i+4) {points += cubic(a,b,c,z);i+=6}
            else if command == "L", let p=xy(i) {points.append(p);i+=2}
            else if command == "Z", let first=points.first {points.append(first);command=""}
            else {return nil}
        }
        return points.count>1 ? TracedPath(points) : nil
    }
    static func logo() -> TracedPath {
        let phase = CGFloat.pi/12
        func rotate(_ x: CGFloat,_ y: CGFloat,_ a: CGFloat) -> CGPoint { CGPoint(x:x*cos(a)-y*sin(a),y:x*sin(a)+y*cos(a)) }
        func mid(_ a:CGPoint,_ b:CGPoint)->CGPoint {CGPoint(x:(a.x+b.x)/2,y:(a.y+b.y)/2)}
        let a0=rotate(102,0,phase),a1=rotate(132,27,phase),a2=rotate(89,100,phase),a3=rotate(51,88.3346,phase)
        let q0=mid(a0,a1),q1=mid(a1,a2),q2=mid(a2,a3),r0=mid(q0,q1),r1=mid(q1,q2),start=mid(r0,r1)
        var p=[start];p += cubic(start,r1,q2,a3)
        for i in 1..<6 {
            let a=phase+CGFloat(i)*CGFloat.pi/3
            p += cubic(p.last!,rotate(132,27,a),rotate(89,100,a),rotate(51,88.3346,a))
        }
        p += cubic(p.last!,q0,r0,start)
        p.append(p[0]);return TracedPath(p)
    }
}

struct StrokePace {
    struct Cell:Hashable {let x:Int,y:Int}
    let step:CGFloat, cumulative:[CGFloat]
    init(_ path:TracedPath,sx:CGFloat,sy:CGFloat,turn:CGFloat,overlap:CGFloat=0) {
        let n=max(2,Int(ceil(path.length/2))),delta=path.length/CGFloat(n)
        step=delta
        let points=(0...n).map { i -> CGPoint in let p=path.point(CGFloat(i)*delta);return CGPoint(x:p.x*sx,y:p.y*sy) }
        let look=max(2,Int(round(11/(delta*min(sx,sy))))),radius=max(3,Int(round(19/(delta*min(sx,sy)))))
        var weights=(0...n).map { i -> CGFloat in
            let p=points[i],a=points[max(0,i-look)],b=points[min(n,i+look)]
            let x=p.x-a.x,y=p.y-a.y,u=b.x-p.x,v=b.y-p.y
            let angle=atan2(abs(x*v-y*u),x*u+y*v)
            return 1+turn*pow(clamp(angle/1.05),1.35)
        }
        if overlap>0 {
            let cell:CGFloat=7,history=Int(ceil(26/(delta*min(sx,sy))))
            var grid:[Cell:[Int]]=[:]
            let tangents=(0...n).map { i -> CGPoint in
                let a=points[max(0,i-2)],b=points[min(n,i+2)],dx=b.x-a.x,dy=b.y-a.y,d=max(0.0001,hypot(dx,dy))
                return CGPoint(x:dx/d,y:dy/d)
            }
            func cellFor(_ p:CGPoint)->Cell {Cell(x:Int(floor(p.x/cell)),y:Int(floor(p.y/cell)))}
            for i in 0...n {
                let j=i-history
                if j>=0 {grid[cellFor(points[j]),default:[]].append(j)}
                let p=points[i],c=cellFor(p),t=tangents[i]
                var nearest:CGFloat=5.5
                for dy in -1...1 {for dx in -1...1 {for k in grid[Cell(x:c.x+dx,y:c.y+dy)] ?? [] {
                    let q=points[k],v=tangents[k]
                    if abs(t.x*v.x+t.y*v.y)<0.86 {continue}
                    nearest=min(nearest,dist(p,q))
                }}}
                weights[i] *= 1-overlap*smooth(clamp(1-nearest/5.5))
            }
        }
        let softened=(0...n).map { i -> CGFloat in
            var sum:CGFloat=0,count:CGFloat=0
            for j in max(0,i-radius)...min(n,i+radius) {let k=CGFloat(radius+1-abs(i-j));sum += k*weights[j];count += k}
            return sum/count
        }
        var times:[CGFloat]=[0]
        for i in 1...n {times.append(times[i-1]+dist(points[i-1],points[i])*(softened[i-1]+softened[i])/2)}
        cumulative=times
    }
    func distance(_ u:CGFloat)->CGFloat {
        var a=0,b=cumulative.count-1;let target=clamp(u)*cumulative[b]
        while a+1<b {let m=(a+b)/2;if cumulative[m]<=target {a=m}else{b=m}}
        let dt=cumulative[b]-cumulative[a]
        return (CGFloat(a)+clamp(dt>0 ? (target-cumulative[a])/dt : 0))*step
    }
}

func makeGrain() -> CGImage {
    // A deterministic, tiny texture tile: fixed pigment grain without a library or file.
    let n=96
    var seed:UInt32=0x4a71de23
    func random()->CGFloat {seed ^= seed << 13;seed ^= seed >> 17;seed ^= seed << 5;return CGFloat(seed & 0xffff)/65535}
    var data=[UInt8](repeating:0,count:n*n*4)
    for i in 0..<(n*n) {
        let x=random(),y=random(),z=random()
        let light=x<0.18
        let opacity=light ? max(0,y-0.30)*0.19 : max(0,y-0.10)*0.23*(0.65+z*0.35)
        let a=UInt8(clamp(opacity)*255),base=light ? CGFloat(255):CGFloat(13)
        data[i*4]=UInt8(base*CGFloat(a)/255);data[i*4+1]=data[i*4];data[i*4+2]=light ? data[i*4]:UInt8(21*CGFloat(a)/255);data[i*4+3]=a
    }
    let provider=CGDataProvider(data:Data(data) as CFData)!
    return CGImage(width:n,height:n,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:n*4,space:cs,bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedLast.rawValue),provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent)!
}

struct TargetWindow {
    let id: CGWindowID
    let rect: CGRect
}
func targetWindow(pid: pid_t, id: CGWindowID? = nil) -> TargetWindow? {
    guard let mainHeight = NSScreen.screens.first?.frame.height,
          let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly,.excludeDesktopElements],kCGNullWindowID) as? [[String:Any]] else {return nil}
    for info in list {
        guard (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
              (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
              let number=(info[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
              id == nil || id == number,
              let dictionary=info[kCGWindowBounds as String] as? [String:Any],
              let r=CGRect(dictionaryRepresentation:dictionary as CFDictionary),r.width>340,r.height>240 else {continue}
        return TargetWindow(id:number, rect:CGRect(x:r.minX,y:mainHeight-r.maxY,width:r.width,height:r.height))
    }
    return nil
}

final class MotionView: NSView {
    let letters: TracedPath, bridge: TracedPath, logo = TracedPath.logo()
    let textGradient = gradient([0xff7a99,0xffa379,0xf8ce80,0xd0e78b,0x83dfc6,0x72cdea,0x9a9df2,0xd2a0f2,0xf99dcb,0xff9a85],[0,0.14,0.26,0.37,0.46,0.53,0.65,0.79,0.91,1])
    let bridgeGradient = gradient([0xff9a85,0xf9b3ad,0xd3a5ed,0xa8baf4],[0,0.32,0.68,1])
    let logoGradient = gradient([0xffcc7c,0xe4de8d,0x85ddd9,0x83ccef,0xc0a7f9],[0,0.28,0.49,0.69,1])
    let backgroundGradient = gradient([0x0a0b15,0x05060c,0x030409],[0,0.67,1])
    let arrow=TracedPath([CGPoint(x:-39,y:-30),CGPoint(x:-13,y:0),CGPoint(x:-39,y:30)])
    let dash=TracedPath([CGPoint(x:6,y:29),CGPoint(x:40,y:29)])
    let grain=makeGrain()
    lazy var textPace=StrokePace(letters,sx:0.76,sy:0.89,turn:0.75,overlap:0.78)
    lazy var bridgePace=StrokePace(bridge,sx:1,sy:1,turn:0.22)
    lazy var logoPace=StrokePace(logo,sx:1,sy:1,turn:0.42)
    // Only the handwriting is rasterized. Its bitmap is small, reusable, and
    // rendered by a CPU bitmap context instead of the window's vector context.
    private lazy var letteringBounds = letters.part(0,letters.length).boundingBoxOfPath.insetBy(dx:-22,dy:-22)
    private var letteringSurface: CGContext?
    private var letteringSurfaceRect = CGRect.zero
    private var letteringSurfacePixels = CGSize.zero
    private var letteringReportedFallback=false
    var t: CGFloat = 0
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    init(frame: NSRect,letters: TracedPath,bridge:TracedPath) {self.letters=letters;self.bridge=bridge;super.init(frame:frame);autoresizingMask=[.width,.height]}
    required init?(coder: NSCoder) {fatalError("not supported")}
    func solid(_ ctx:CGContext,_ path:CGPath,width:CGFloat,fill:CGColor,alpha:CGFloat=1) {
        if path.isEmpty || alpha<0.001 {return}
        ctx.saveGState();ctx.setAlpha(alpha);ctx.setLineWidth(width);ctx.setLineCap(.round);ctx.setLineJoin(.round);ctx.setStrokeColor(fill);ctx.addPath(path);ctx.strokePath();ctx.restoreGState()
    }
    func shaded(_ ctx:CGContext,_ path:CGPath,width:CGFloat=13,gradient:CGGradient,from:CGPoint,to:CGPoint,alpha:CGFloat=1,glow:Bool=true,texture:CGFloat=1) {
        if path.isEmpty || alpha < 0.001 { return }
        if glow { solid(ctx,path,width:width+3,fill:color(0xb4c5fb),alpha:alpha*0.038) }
        ctx.saveGState();ctx.setAlpha(alpha);ctx.setLineWidth(width);ctx.setLineCap(.round);ctx.setLineJoin(.round);ctx.addPath(path);ctx.replacePathWithStrokedPath();ctx.clip();ctx.drawLinearGradient(gradient,start:from,end:to,options:[.drawsBeforeStartLocation,.drawsAfterEndLocation])
        if texture>0.005 {ctx.setAlpha(alpha*texture);ctx.interpolationQuality = .none;ctx.draw(grain,in:CGRect(x:0,y:0,width:69,height:69),byTiling:true)}
        ctx.restoreGState()
    }
    private func paintLettering(_ ctx:CGContext,distance:CGFloat,alpha:CGFloat,activeAlpha:CGFloat) {
        shaded(ctx,letters.part(0,distance),gradient:textGradient,from:CGPoint(x:153,y:0),to:CGPoint(x:1724,y:0),alpha:alpha)
        if activeAlpha>0 {
            solid(ctx,letters.part(max(0,distance-23),distance),width:4.2,fill:color(0xffffff),alpha:activeAlpha)
        }
    }
    private func rasterizedLettering(_ target:CGContext,distance:CGFloat,alpha:CGFloat,activeAlpha:CGFloat) {
        guard distance>0.01,alpha>0.001 else {return}
        // Align the reusable surface to physical pixels. This avoids introducing
        // a second fractional-pixel resampling step when compositing the image.
        let deviceRect=target.convertToDeviceSpace(letteringBounds).standardized.integral
        let mappedRect=target.convertToUserSpace(deviceRect).standardized
        let aligned = !mappedRect.isNull && !mappedRect.isEmpty && deviceRect.width.isFinite && deviceRect.height.isFinite && deviceRect.width>=1 && deviceRect.height>=1 && deviceRect.width*deviceRect.height<=12_000_000
        let rect=aligned ? mappedRect : letteringBounds
        // Never fall back to the window's clip/stroke renderer. If a display
        // transition temporarily doesn't offer a usable physical transform,
        // use a smaller normalized bitmap until a valid mapping returns.
        let w=aligned ? Int(deviceRect.width) : Int(ceil(rect.width*1.5))
        let h=aligned ? Int(deviceRect.height) : Int(ceil(rect.height*1.5))
        if !aligned && !letteringReportedFallback {letteringReportedFallback=true;letteringLog.info("LETTERING_BITMAP using normalized fallback")}
        let pixels=CGSize(width:w,height:h)
        if letteringSurface == nil || letteringSurfacePixels != pixels || abs(letteringSurfaceRect.minX-rect.minX)>0.00001 || abs(letteringSurfaceRect.minY-rect.minY)>0.00001 || abs(letteringSurfaceRect.width-rect.width)>0.00001 || abs(letteringSurfaceRect.height-rect.height)>0.00001 {
            var actualW=w,actualH=h
            letteringSurface=CGContext(data:nil,width:actualW,height:actualH,bitsPerComponent:8,bytesPerRow:0,space:cs,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)
            if letteringSurface == nil {
                actualW=max(1,w/2);actualH=max(1,h/2)
                letteringSurface=CGContext(data:nil,width:actualW,height:actualH,bitsPerComponent:8,bytesPerRow:0,space:cs,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)
            }
            letteringSurfacePixels=pixels;letteringSurfaceRect=rect
            if let surface=letteringSurface {
                surface.translateBy(x:0,y:CGFloat(actualH))
                surface.scaleBy(x:CGFloat(actualW)/rect.width,y:-CGFloat(actualH)/rect.height)
                surface.translateBy(x:-rect.minX,y:-rect.minY)
                letteringLog.info("LETTERING_BITMAP \(actualW)x\(actualH) aligned=\(aligned)")
            }
        }
        guard let surface=letteringSurface else {return}
        surface.clear(rect)
        paintLettering(surface,distance:distance,alpha:alpha,activeAlpha:activeAlpha)
        guard let image=surface.makeImage() else {return}
        target.saveGState();target.interpolationQuality = aligned ? .none : .high
        target.translateBy(x:rect.minX,y:rect.maxY);target.scaleBy(x:1,y:-1)
        target.draw(image,in:CGRect(x:0,y:0,width:rect.width,height:rect.height))
        target.restoreGState()
    }
    func logoTransform(_ t:CGFloat,sceneScale:CGFloat)->(CGFloat,CGFloat,CGFloat,CGFloat) {
        let portal=progress(t,MotionTiming.portalStart,MotionTiming.portalEnd)
        // A wider or taller window must still be fully revealed at the end.
        let needed=hypot(bounds.width/2,bounds.height/2)/(max(sceneScale,0.01)*95.5)*1.08
        let zoom=exp(log(max(exp(2.62),needed))*(portal*portal*0.35+portal*0.65))
        return(800,500,zoom,zoom)
    }
    override func draw(_ dirtyRect: NSRect) {
        guard let ctx=NSGraphicsContext.current?.cgContext else {return}
        ctx.clear(bounds)
        let w=bounds.width,h=bounds.height,scale=min(w/1600,h/1000)
        guard scale>0 else {return}
        let ox=(w-1600*scale)/2,oy=(h-1000*scale)/2
        ctx.saveGState();ctx.addPath(CGPath(roundedRect:bounds,cornerWidth:13,cornerHeight:13,transform:nil));ctx.clip()
        let (cx,cy,sx,sy)=logoTransform(t,sceneScale:scale), portalAlpha=smooth(progress(t,MotionTiming.portalStart,MotionTiming.portalStart+0.20))
        let normalizedLogo=logo.part(0,logo.length,close:true)
        var holeTransform=CGAffineTransform(translationX:ox+scale*cx,y:oy+scale*cy).scaledBy(x:scale*sx*0.955,y:scale*sy*0.955)
        let hole=normalizedLogo.copy(using:&holeTransform)!
        ctx.saveGState()
        ctx.addRect(bounds)
        if portalAlpha > 0 {ctx.addPath(hole)}
        ctx.clip(using:.evenOdd)
        let mid=CGPoint(x:w*0.48,y:h*0.52)
        ctx.drawRadialGradient(backgroundGradient,startCenter:mid,startRadius:0,endCenter:mid,endRadius:hypot(w,h)*0.6,options:[.drawsAfterEndLocation]);ctx.restoreGState()
        if portalAlpha>0 && portalAlpha<1 {ctx.saveGState();ctx.setFillColor(color(0x070810,1-portalAlpha));ctx.addPath(hole);ctx.fillPath();ctx.restoreGState()}
        // Everything outside the portal remains black; the cutout itself has real window alpha.
        ctx.translateBy(x:ox,y:oy);ctx.scaleBy(x:scale,y:scale)
        let writeEnd=MotionTiming.writeEnd,bridgeEnd=MotionTiming.bridgeEnd,logoEnd=MotionTiming.logoEnd,portalStart=MotionTiming.portalStart,portalEnd=MotionTiming.portalEnd
        let distance=textPace.distance(velocityRamp(progress(t,MotionTiming.writeStart,writeEnd),initial:0.18,final:0.76))
        let bridgeDist=bridgePace.distance(velocityRamp(progress(t,writeEnd,bridgeEnd),initial:0.94,final:0.88,a:0.10,b:0.10))
        let logoDist=logoPace.distance(velocityRamp(progress(t,bridgeEnd,logoEnd),initial:0.92,final:0.12,a:0.07,b:0.11))
        let decay=smooth(progress(t,writeEnd-0.02,bridgeEnd+0.38)),bridgeTail=bridge.length*smooth(progress(t,writeEnd+0.34,bridgeEnd+0.34))
        ctx.saveGState();ctx.translateBy(x:82,y:82);ctx.scaleBy(x:0.76,y:0.89)
        let activeAlpha:CGFloat=t>=MotionTiming.writeStart && t<writeEnd ? 0.11*smooth(progress(t,MotionTiming.writeStart,MotionTiming.writeStart+0.15))*(1-smooth(progress(t,writeEnd-0.13,writeEnd))) : 0
        rasterizedLettering(ctx,distance:distance,alpha:1-decay,activeAlpha:activeAlpha)
        ctx.restoreGState()
        shaded(ctx,bridge.part(min(bridgeDist,bridgeTail),bridgeDist),width:11,gradient:bridgeGradient,from:CGPoint(x:1392,y:545),to:CGPoint(x:883,y:583),alpha:1-smooth(progress(t,bridgeEnd+0.05,bridgeEnd+0.36)))
        ctx.saveGState();ctx.translateBy(x:cx,y:cy);ctx.scaleBy(x:sx,y:sy)
        let logoAlpha=1-smooth(progress(t,portalEnd-0.14,portalEnd+0.02))
        let echo=0.17*smooth(progress(t,portalStart+0.07,portalStart+0.38))*(1-smooth(progress(t,portalStart+0.55,portalEnd)))*logoAlpha
        if echo>0 {ctx.saveGState();ctx.scaleBy(x:1.19,y:1.19);shaded(ctx,normalizedLogo,width:3.3,gradient:logoGradient,from:CGPoint(x:-125,y:18),to:CGPoint(x:122,y:-15),alpha:echo,glow:false,texture:0);ctx.restoreGState()}
        shaded(ctx,logo.part(0,logoDist,close:logoDist>=logo.length-0.01),width:11/sqrt(sx),gradient:logoGradient,from:CGPoint(x:-125,y:18),to:CGPoint(x:122,y:-15),alpha:logoAlpha,texture:1-smooth(progress(t,portalStart,portalStart+0.27)))
        let mark=smooth(progress(t,logoEnd-0.27,logoEnd+0.15))*(1-smooth(progress(t,portalStart,portalStart+0.30))),markProgress=progress(t,logoEnd-0.22,logoEnd+0.18)
        solid(ctx,arrow.part(0,arrow.length*pen(markProgress)),width:11.5,fill:color(0xf3f6fc),alpha:mark)
        solid(ctx,dash.part(0,dash.length*smooth(progress(markProgress,0.43,1))),width:11.5,fill:color(0xf3f6fc),alpha:mark)
        ctx.restoreGState()
        var tip:CGPoint?;var tipAlpha:CGFloat=0
        if t>=MotionTiming.writeStart && t<writeEnd {let p=letters.point(distance);tip=CGPoint(x:82+0.76*p.x,y:82+0.89*p.y);tipAlpha=0.43*smooth(progress(t,MotionTiming.writeStart,MotionTiming.writeStart+0.12))}
        else if t>=writeEnd && t<bridgeEnd {tip=bridge.point(bridgeDist);tipAlpha=0.43}
        else if t>=bridgeEnd && t<logoEnd {let p=logo.point(logoDist);tip=CGPoint(x:800+p.x,y:500+p.y);tipAlpha=0.43*(1-smooth(progress(t,logoEnd-0.15,logoEnd)))}
        if let p=tip,tipAlpha>0 {ctx.setFillColor(color(0xffffff,tipAlpha));ctx.fillEllipse(in:CGRect(x:p.x-2.6,y:p.y-2.6,width:5.2,height:5.2))}
        ctx.restoreGState()
    }
}

final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

