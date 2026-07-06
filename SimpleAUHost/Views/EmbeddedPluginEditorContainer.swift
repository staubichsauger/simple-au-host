import AppKit
import SwiftUI

struct EmbeddedPluginEditorContainer: NSViewControllerRepresentable {
    let viewController: NSViewController

    func makeNSViewController(context: Context) -> NSViewController {
        HostingEditorViewController(contentViewController: viewController)
    }

    func updateNSViewController(_ nsViewController: NSViewController, context: Context) {
        guard let hostingController = nsViewController as? HostingEditorViewController else { return }
        hostingController.setContentViewController(viewController)
    }
}

private final class HostingEditorViewController: NSViewController {
    private var hostedViewController: NSViewController?
    private let canvasView = FlippedCanvasView()

    init(contentViewController: NSViewController) {
        super.init(nibName: nil, bundle: nil)
        setContentViewController(contentViewController)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func loadView() {
        canvasView.translatesAutoresizingMaskIntoConstraints = false
        canvasView.clipsToBounds = true
        view = canvasView
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        hostedViewController?.view.layoutSubtreeIfNeeded()
    }

    func setContentViewController(_ viewController: NSViewController) {
        guard hostedViewController !== viewController else { return }

        hostedViewController?.view.removeFromSuperview()
        hostedViewController?.removeFromParent()

        hostedViewController = viewController
        loadViewIfNeeded()
        addChild(viewController)

        let hostedView = viewController.view
        hostedViewController?.view.layoutSubtreeIfNeeded()
        hostedView.layoutSubtreeIfNeeded()

        let fittingSize = hostedView.fittingSize
        let preferredSize = viewController.preferredContentSize
        let frameSize = hostedView.frame.size
        let boundsSize = hostedView.bounds.size
        let width = max(520, fittingSize.width, preferredSize.width, frameSize.width, boundsSize.width)
        let height = max(360, fittingSize.height, preferredSize.height, frameSize.height, boundsSize.height)

        hostedView.frame = NSRect(x: 0, y: 0, width: width, height: height)
        hostedView.bounds = NSRect(x: 0, y: 0, width: width, height: height)
        hostedView.translatesAutoresizingMaskIntoConstraints = false
        canvasView.subviews.forEach { $0.removeFromSuperview() }
        canvasView.addSubview(hostedView)
        canvasView.needsLayout = true

        NSLayoutConstraint.activate([
            hostedView.leadingAnchor.constraint(equalTo: canvasView.leadingAnchor),
            hostedView.topAnchor.constraint(equalTo: canvasView.topAnchor),
            hostedView.widthAnchor.constraint(equalToConstant: width),
            hostedView.heightAnchor.constraint(equalToConstant: height)
        ])
    }
}

private final class FlippedCanvasView: NSView {
    override var isFlipped: Bool { true }
}
