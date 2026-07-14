import { HttpClientTestingModule, HttpTestingController } from '@angular/common/http/testing';
import { TestBed } from '@angular/core/testing';
import { environment } from '../../environments/environment';
import { Message } from '../models/message.model';
import { MessagesStoreService } from './messages-store.service';

describe('MessagesStoreService', () => {
  let service: MessagesStoreService;
  let httpMock: HttpTestingController;
  const baseUrl = `${environment.apiBaseUrl}/api/v1/messages`;

  const newerMessage: Message = {
    id: '2',
    to_number: '+14155550123',
    body: 'fresh response',
    status: 'sent',
    external_sid: 'FAKE-2',
    created_at: '2020-05-17T11:18:45Z',
  };

  beforeEach(() => {
    TestBed.configureTestingModule({
      imports: [HttpClientTestingModule],
      providers: [MessagesStoreService],
    });
    service = TestBed.inject(MessagesStoreService);
    httpMock = TestBed.inject(HttpTestingController);
  });

  afterEach(() => {
    httpMock.verify();
  });

  it('fetches messages and publishes them on messages$', () => {
    service.refresh();
    const req = httpMock.expectOne(baseUrl);
    req.flush({ count: 1, messages: [newerMessage] });

    let latest: Message[] = [];
    service.messages$.subscribe((messages) => (latest = messages));
    expect(latest).toEqual([newerMessage]);
  });

  it('publishes an error and clears loading when the request fails', () => {
    service.refresh();
    const req = httpMock.expectOne(baseUrl);
    req.error(new ProgressEvent('error'), { status: 500, statusText: 'Server Error' });

    const state: { error: string | null; loading: boolean } = { error: null, loading: true };
    service.error$.subscribe((e) => (state.error = e));
    service.loading$.subscribe((l) => (state.loading = l));

    expect(state.error).toBe('Failed to load message history. Please try again.');
    expect(state.loading).toBeFalse();
  });

  it('does not let a stale, slower refresh() response overwrite a newer one (QA report round1 M4)', () => {
    // First refresh() starts a GET that will resolve LAST (simulating a slow
    // network response).
    service.refresh();
    const firstReq = httpMock.expectOne(baseUrl);

    // A second refresh() fires before the first has resolved (e.g. a fast
    // double-click, or a send-triggered refresh landing while the initial
    // load is still in-flight). Because MessagesStoreService pipes refresh
    // triggers through switchMap, this cancels/unsubscribes the first
    // request — HttpClientTestingModule surfaces this as `cancelled: true`
    // on the original TestRequest.
    service.refresh();
    expect(firstReq.cancelled).toBeTrue();

    const secondReq = httpMock.expectOne(baseUrl);
    secondReq.flush({ count: 1, messages: [newerMessage] });

    let latest: Message[] = [];
    service.messages$.subscribe((messages) => (latest = messages));
    expect(latest).toEqual([newerMessage]);
  });
});
