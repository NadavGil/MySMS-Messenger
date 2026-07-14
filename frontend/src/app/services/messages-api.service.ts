import { HttpClient } from '@angular/common/http';
import { Injectable } from '@angular/core';
import { Observable } from 'rxjs';
import { environment } from '../../environments/environment';
import { ListMessagesResponse, Message, SendMessagePayload } from '../models/message.model';

/**
 * Thin HttpClient wrapper around the Rails API (tech-design.md §8.3).
 *
 * All calls set `withCredentials: true` so the signed session cookie
 * round-trips (pairs with the backend's `credentials: true` CORS config,
 * tech-design.md §2.10). Base URL comes from environment config — never
 * hard-coded.
 */
@Injectable({ providedIn: 'root' })
export class MessagesApiService {
  // Convention: `environment.apiBaseUrl` is ONLY an origin (or '' for a
  // same-origin/reverse-proxied deploy) — it must never itself contain
  // `/api`. This service is the single place that appends the API path, so
  // all environment files stay consistent and can't silently double up the
  // `/api` segment again (see environment.production.ts comment; QA report
  // round1 M2 — production previously resolved to `/api/api/v1/messages`).
  private readonly baseUrl = `${environment.apiBaseUrl}/api/v1/messages`;

  constructor(private readonly http: HttpClient) {}

  /** POST /api/v1/messages */
  sendMessage(payload: SendMessagePayload): Observable<Message> {
    return this.http.post<Message>(this.baseUrl, payload, { withCredentials: true });
  }

  /** GET /api/v1/messages */
  listMessages(): Observable<ListMessagesResponse> {
    return this.http.get<ListMessagesResponse>(this.baseUrl, { withCredentials: true });
  }
}
