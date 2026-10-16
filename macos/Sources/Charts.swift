import AppKit

@MainActor final class ActivityChart: NSView {
    struct Point { let date: String; let value: Double; let detail: String }
    var points: [Point] = [] { didSet { needsDisplay=true; refreshAccessibility() } }
    var heatmap = false
    var unit = "字"
    private var hitAreas: [(NSRect,String)] = []
    override var isFlipped: Bool { true }
    override init(frame: NSRect) {super.init(frame:frame);setAccessibilityElement(true);setAccessibilityRole(.image)}
    required init?(coder:NSCoder){fatalError()}
    private func refreshAccessibility(){setAccessibilityLabel((heatmap ? "每日活動熱圖。" : "每日趨勢。") + points.filter{$0.value>0}.map{$0.date+"："+$0.detail}.joined(separator:"；"))}
    override func draw(_ dirtyRect:NSRect){
        super.draw(dirtyRect);removeAllToolTips();hitAreas=[]
        guard !points.isEmpty else {return}
        let peak=points.map(\.value).max() ?? 0
        let maximum=peak>0 ? peak : 1
        if heatmap {
            let gap:CGFloat=3, cols=52
            let size=min(14,(bounds.width-CGFloat(cols-1)*gap)/CGFloat(cols))
            for (i,p) in points.suffix(364).enumerated() {
                let rect=NSRect(x:CGFloat(i/7)*(size+gap),y:CGFloat(i%7)*(size+gap)+22,width:size,height:size)
                let strength=p.value==0 ? 0 : 0.25+0.75*sqrt(p.value/maximum)
                NSColor(calibratedRed:0.30+0.40*strength,green:0.32+0.47*strength,blue:0.36+0.60*strength,alpha:1).setFill()
                NSBezierPath(roundedRect:rect,xRadius:3,yRadius:3).fill();hitAreas.append((rect,p.date+" · "+p.detail))
            }
            text(points.first?.date ?? "",at:NSPoint(x:0,y:0));text(points.last?.date ?? "",at:NSPoint(x:max(0,bounds.width-95),y:0))
            text("較少  ▪ ▪ ▪ ▪  較多 · 移到方格查看日期",at:NSPoint(x:0,y:bounds.height-20))
        } else {
            let height=max(20,bounds.height-48), gap:CGFloat=5
            let width=max(1,(bounds.width-CGFloat(points.count-1)*gap)/CGFloat(points.count))
            for (i,p) in points.enumerated(){
                let barHeight=max(2,height*p.value/maximum)
                let rect=NSRect(x:CGFloat(i)*(width+gap),y:height-barHeight+20,width:width,height:barHeight)
                (p.value>0 ? NSColor(calibratedRed:0.67,green:0.75,blue:0.96,alpha:1) : NSColor(calibratedWhite:0.35,alpha:1)).setFill()
                NSBezierPath(roundedRect:rect,xRadius:min(4,width/2),yRadius:3).fill()
                hitAreas.append((NSRect(x:rect.minX,y:0,width:width,height:bounds.height),p.date+" · "+p.detail))
            }
            text("最高 \(unit == "USD" ? InsightFormat.usd(peak) : String(Int(points.map(\.value).max() ?? 0))) \(unit)",at:NSPoint(x:0,y:0))
            text(points.first?.date ?? "",at:NSPoint(x:0,y:bounds.height-20));text(points.last?.date ?? "",at:NSPoint(x:max(0,bounds.width-95),y:bounds.height-20))
        }
        for (rect,_) in hitAreas {addToolTip(rect,owner:self,userData:nil)}
    }
    private func text(_ value:String,at point:NSPoint){(value as NSString).draw(at:point,withAttributes:[.font:NSFont.systemFont(ofSize:11),.foregroundColor:NSColor.secondaryLabelColor])}
    func view(_ view:NSView,stringForToolTip tag:NSView.ToolTipTag,point:NSPoint,userData:UnsafeMutableRawPointer?) -> String {hitAreas.first{$0.0.contains(point)}?.1 ?? ""}
}
