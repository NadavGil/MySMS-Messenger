/**
 * TS interfaces mirroring the API contract in tech-design.md §6.
 */

// Bug blitz (2026-07-16) fix: this type only listed the pre-Bonus-3 values
// and was never updated when the backend's MessageDocument::STATUSES grew
// to include the Twilio delivery-status webhook's terminal values (Bonus 3,
// tech-design.md §15.4) — a stale type, not a runtime bug (TS structural
// typing meant a real 'delivered' string from the API still flowed through
// fine), but it meant nothing in the frontend could name these statuses
// without an `as any` cast. Now matches the backend vocabulary exactly.
export type MessageStatus = 'queued' | 'sent' | 'failed' | 'delivered' | 'undelivered';

/** A single persisted message, as returned by the API (§6.1 / §6.2). */
export interface Message {
  id: string;
  to_number: string;
  body: string;
  status: MessageStatus;
  external_sid: string | null;
  created_at: string; // ISO-8601 UTC
}

/** Request payload for `POST /api/v1/messages` (§6.1). */
export interface SendMessagePayload {
  to_number: string;
  body: string;
}

/** Response shape for `GET /api/v1/messages` (§6.2). */
export interface ListMessagesResponse {
  count: number;
  messages: Message[];
}

/** Response shape for a validation error, `422` (§6.1). */
export interface ApiErrorResponse {
  errors: Record<string, string[]>;
}
