import Foundation

enum AICalendarPrompt {
    static let userText = "Extract explicit calendar events from this screenshot"

    static func make(
        now: Date = Date(),
        calendar: Calendar = .current,
        timeZone: TimeZone = .current
    ) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = timeZone
        let localNow = formatter.string(from: now)

        return """
        You extract calendar events from a screenshot. Return only one valid JSON object with an events array. Do not return Markdown fences, explanations, or any text outside JSON.

        Current local date and time: \(localNow)
        Calendar: \(calendar.identifier)
        Time zone: \(timeZone.identifier)

        Extract only events explicitly supported by the screenshot. Never guess or invent a title, date, time, duration, person, location, URL, or calendar assignment. Return every explicit event, including multiple events. If no event is explicit, return {"events":[]}.

        Each event must use only these fields: title, calendar_type, start, end, location, notes, url, attendees, requires_confirmation, uncertain_fields, confidence. calendar_type must be exactly work, personal, or unknown. Use unknown when the screenshot does not establish a work or personal context and set requires_confirmation to true.

        Use ISO-8601 date-time strings with an explicit time zone for known dates and times. For every missing or ambiguous field, use null, set requires_confirmation to true, and list that field in uncertain_fields. Never turn words such as afternoon, evening, later, or after lunch into a guessed clock time. A known start with no stated end may use a one-hour end only when that default is clearly appropriate. Preserve an explicitly stated approximate duration such as about half an hour when it can determine end; otherwise use null and request confirmation.

        Do not create all-day events, repeated instances, recurrence rules, alarms, or reminders. Put explicit recurrence or repetition wording in notes. Preserve the screenshot's description and relevant context in notes without adding facts. URLs must be ordinary http or https URLs. Attendees may contain name and email fields.
        """
    }

    static func systemPrompt(
        now: Date = Date(),
        calendar: Calendar = .current,
        timeZone: TimeZone = .current
    ) -> String {
        make(now: now, calendar: calendar, timeZone: timeZone)
    }
}
