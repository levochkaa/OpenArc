// BrowserProductLogo.swift

import AppKit

/// OpenArc's icon for the engine's own pages (History, Settings, Downloads),
/// whose toolbars otherwise show the engine's logo.
@MainActor @objc final class BrowserProductLogo: NSObject {
    /// The app icon without its transparent margin, as a 256 px PNG data URL
    /// so it stays sharp on Retina screens. Made once.
    @objc static let dataURL: String? = {
        let icon = NSImage(named: "AppIcon") ?? NSApp.applicationIconImage
        var rect = CGRect(x: 0, y: 0, width: 1024, height: 1024)
        guard let icon, let full = icon.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return nil }
        let inset = (CGFloat(full.width) * artInset).rounded()
        let art = CGRect(x: 0, y: 0, width: full.width, height: full.height).insetBy(dx: inset, dy: inset)
        guard let cropped = full.cropping(to: art),
              let encoded = NSBitmapImageRep(cgImage: cropped).representation(using: .png, properties: [:]),
              let image = BrowserImageThumbnailer.image(data: encoded, maximumPixelSize: 256),
              let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
        else { return nil }
        return "data:image/png;base64," + png.base64EncodedString()
    }()

    /// The transparent margin around the icon's art, as a share of its width.
    private static let artInset: CGFloat = 100 / 1024

    /// Replaces the logos of an internal page, inside its shadow roots, once
    /// the page has drawn them, at the size the engine's logo had. Settings draws another on its About page when
    /// that opens, so it keeps looking there.
    @objc static func script(dataURL: String) -> String {
        """
        (function(){var logo=\(String(reflecting: dataURL));
        function swap(root,depth){if(!root||depth>8)return 0;var n=0;
        root.querySelectorAll('img#product-logo').forEach(function(img){if(img.dataset.openarcLogo)return;
        var r=img.getBoundingClientRect();if(!r.width||!r.height)return;
        img.style.width=r.width+'px';img.style.height=r.height+'px';img.style.objectFit='contain';
        var p=img.parentNode;if(p&&p.tagName==='PICTURE'){p.querySelectorAll('source').forEach(function(s){s.remove();});}
        img.removeAttribute('srcset');img.src=logo;img.dataset.openarcLogo='1';n++;});
        var all=root.querySelectorAll('*');for(var i=0;i<all.length;i++){if(all[i].shadowRoot)n+=swap(all[i].shadowRoot,depth+1);}
        return n;}
        var settings=location.host==='settings';var swapped=0;var tries=0;
        var timer=setInterval(function(){swapped+=swap(document,0);tries++;
        if(!settings&&(swapped>0||tries>100)){clearInterval(timer);}
        else if(settings&&tries===100){clearInterval(timer);setInterval(function(){swap(document,0);},500);}},50);})();
        """
    }
}
