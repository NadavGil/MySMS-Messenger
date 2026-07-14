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
