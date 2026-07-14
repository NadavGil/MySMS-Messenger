/**
 * TS interfaces mirroring the API contract in tech-design.md §6.
 */

export type MessageStatus = 'queued' | 'sent' | 'failed';

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
