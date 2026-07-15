/** Auth API request/response shapes (tech-design.md §13.7). */

export interface AuthUser {
  id: string;
  username: string;
}

export interface SignupPayload {
  username: string;
  password: string;
}

export interface LoginPayload {
  username: string;
  password: string;
}
