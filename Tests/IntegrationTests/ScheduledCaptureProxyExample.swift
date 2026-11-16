// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the swift-wire project authors

import Wire
import WireTestLibrary

/// A bridging contributor proxy whose only link to a scheduled binding is its scope-entry thunk's capture.
///
/// The default graph is scheduled: `AsyncToken` and `AsyncMessage` are independent async bindings, so both
/// are in its Overlap. `ScheduledCaptureReceipt` waits on both, which puts it in the serial suffix — bound
/// only after the group has drained. The seed scope borrows the receipt, and the proxy over the scope's
/// subject has no other dependency, so the thunk's capture is the only edge between the proxy and anything
/// scheduled. The regions have to count that edge: without it the proxy lands in the prefix, and its thunk
/// captures a local the seam has not bound yet, which does not compile.
///
/// The receipt is a *suffix* binding rather than a group one on purpose. A capture of a group binding puts
/// the thunk in the group, and the scheduler then keeps the whole graph on the linear chain — correct, but
/// it would take the default graph's scheduling away from every other fixture that relies on it. A suffix
/// capture is emitted after the seam and leaves the group untouched.
package struct ScheduledCaptureSeed: Sendable {
    package let id: String
}

/// Waits on every member of the default graph's Overlap, so it is built after the seam.
@Singleton(allowUnused: true)
package struct ScheduledCaptureReceipt: Sendable {
    package let summary: String

    @Inject package init(token: AsyncToken, message: AsyncMessage) {
        self.summary = "\(token.value)+\(message.payload)"
    }
}

/// The routed subject. Its only app singleton is the borrowed receipt.
@Scoped(seed: ScheduledCaptureSeed.self, allowUnused: true)
@RouteController
package struct ScheduledCaptureController {
    @Inject package var receipt: ScheduledCaptureReceipt
    @Inject package var scheduledCaptureSeed: ScheduledCaptureSeed

    package func describe() -> String { "\(scheduledCaptureSeed.id):\(receipt.summary)" }
}
