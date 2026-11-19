// ApprovalDemo.swift — approvals lane: deterministic demo fixtures.
// Shaped like the Graph beta `approvalItem` payloads so the demo path
// exercises the real decode + flow-status code. Western names only.
import Foundation

enum ApprovalDemo {
    static func listData() throws -> Data {
        Data(
            """
            {"value":[
            {"id":"demo-appr-1","displayName":"Travel request — Chicago client onsite",
            "description":"Two nights, flights + hotel, week of Dec 8.",
            "approvalType":"basic","state":"pending","allowCancel":true,
            "createdDateTime":"2026-11-10T14:00:00Z",
            "owner":{"user":{"id":"demo-u-you","displayName":"You"}},
            "approvers":[{"user":{"id":"demo-u-oliver","displayName":"Oliver Grant"}},
            {"user":{"id":"demo-u-ava","displayName":"Ava Lindqvist"}}],
            "responsePrompts":["Approve","Reject"]},
            {"id":"demo-appr-2","displayName":"Vendor contract renewal",
            "description":"Annual renewal for the transcription service.",
            "approvalType":"basicAwaitAll","state":"pending","allowCancel":true,
            "createdDateTime":"2026-11-12T09:30:00Z",
            "owner":{"user":{"id":"demo-u-you","displayName":"You"}},
            "approvers":[{"user":{"id":"demo-u-tom","displayName":"Tom Becker"}},
            {"user":{"id":"demo-u-ava","displayName":"Ava Lindqvist"}}],
            "responsePrompts":["Approve","Reject"]},
            {"id":"demo-appr-3","displayName":"New laptop request",
            "description":"Replacement for the 2021 machine.",
            "approvalType":"basic","state":"completed","result":"Approved",
            "allowCancel":false,
            "createdDateTime":"2026-10-28T16:45:00Z",
            "completedDateTime":"2026-10-29T10:15:00Z",
            "owner":{"user":{"id":"demo-u-you","displayName":"You"}},
            "approvers":[{"user":{"id":"demo-u-oliver","displayName":"Oliver Grant"}}],
            "responsePrompts":["Approve","Reject"]},
            {"id":"demo-appr-4","displayName":"Conference travel — spring",
            "description":"Withdrawn after the schedule changed.",
            "approvalType":"basic","state":"canceled","allowCancel":false,
            "createdDateTime":"2026-10-15T11:00:00Z",
            "owner":{"user":{"id":"demo-u-you","displayName":"You"}},
            "approvers":[{"user":{"id":"demo-u-tom","displayName":"Tom Becker"}}],
            "responsePrompts":["Approve","Reject"]}
            ]}
            """.utf8)
    }

    static func responsesData(for id: String) throws -> Data {
        let value: String
        switch id {
        case "demo-appr-1":
            value = """
            {"value":[
            {"id":"demo-resp-1","response":"Approve","comments":"Looks good.",
            "createdDateTime":"2026-11-10T15:20:00Z",
            "responder":{"user":{"id":"demo-u-oliver","displayName":"Oliver Grant"}}}]}
            """
        case "demo-appr-3":
            value = """
            {"value":[
            {"id":"demo-resp-3","response":"Approve","comments":"Approved.",
            "createdDateTime":"2026-10-29T10:15:00Z",
            "responder":{"user":{"id":"demo-u-oliver","displayName":"Oliver Grant"}}}]}
            """
        default:
            value = "{\"value\":[]}"
        }
        return Data(value.utf8)
    }
}
