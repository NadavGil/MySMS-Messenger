import { HttpClient } from '@angular/common/http';
import { Injectable } from '@angular/core';
import { Observable } from 'rxjs';
import { environment } from '../../environments/environment';
import { AuthUser, LoginPayload, SignupPayload } from '../models/auth.model';

/**
 * Thin HttpClient wrapper around the Rails auth API (tech-design.md §13.7).
 *
 * Mirrors `MessagesApiService`'s conventions: `environment.apiBaseUrl` is an
 * origin-or-empty value only, this service owns the `/api/v1/auth` path
 * segment, and every call sets `withCredentials: true` so the signed
 * `:msms_owner` HttpOnly session cookie round-trips (same CORS
 * `credentials: true` contract, tech-design.md §2.10/§13.1).
 */
@Injectable({ providedIn: 'root' })
export class AuthApiService {
  private readonly baseUrl = `${environment.apiBaseUrl}/api/v1/auth`;

  constructor(private readonly http: HttpClient) {}

  /** POST /api/v1/auth/signup -> 201 { id, username } / 422 { errors } */
  signup(payload: SignupPayload): Observable<AuthUser> {
    return this.http.post<AuthUser>(`${this.baseUrl}/signup`, payload, { withCredentials: true });
  }

  /** POST /api/v1/auth/login -> 200 { id, username } / 401 { errors } */
  login(payload: LoginPayload): Observable<AuthUser> {
    return this.http.post<AuthUser>(`${this.baseUrl}/login`, payload, { withCredentials: true });
  }

  /** DELETE /api/v1/auth/logout -> 204 No Content */
  logout(): Observable<void> {
    return this.http.delete<void>(`${this.baseUrl}/logout`, { withCredentials: true });
  }

  /** GET /api/v1/auth/me -> 200 { id, username } / 401 { errors } */
  me(): Observable<AuthUser> {
    return this.http.get<AuthUser>(`${this.baseUrl}/me`, { withCredentials: true });
  }
}
