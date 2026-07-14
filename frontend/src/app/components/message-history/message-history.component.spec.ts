import { HttpClientTestingModule, HttpTestingController } from '@angular/common/http/testing';
import { ComponentFixture, TestBed } from '@angular/core/testing';
import { environment } from '../../../environments/environment';
import { Message } from '../../models/message.model';
import { MessageHistoryComponent } from './message-history.component';

describe('MessageHistoryComponent', () => {
  let fixture: ComponentFixture<MessageHistoryComponent>;
  let httpMock: HttpTestingController;
  const baseUrl = `${environment.apiBaseUrl}/api/v1/messages`;

  const sampleMessages: Message[] = [
    {
      id: '1',
      to_number: '+14155550123',
      body: 'Hello there',
      status: 'sent',
      external_sid: 'FAKE-1',
      created_at: '2020-05-17T11:18:45Z',
    },
    {
      id: '2',
      to_number: '+14155550199',
      body: 'Second message',
      status: 'sent',
      external_sid: 'FAKE-2',
      created_at: '2020-05-16T09:02:11Z',
    },
  ];

  beforeEach(async () => {
    await TestBed.configureTestingModule({
      imports: [MessageHistoryComponent, HttpClientTestingModule],
    }).compileComponents();

    fixture = TestBed.createComponent(MessageHistoryComponent);
    httpMock = TestBed.inject(HttpTestingController);
  });

  afterEach(() => {
    httpMock.verify();
  });

  it('creates the component and fetches history on init', () => {
    fixture.detectChanges();
    const req = httpMock.expectOne(baseUrl);
    expect(req.request.method).toBe('GET');
    req.flush({ count: 0, messages: [] });
  });

  it('renders the "Message History (N)" header with the live count', () => {
    fixture.detectChanges();
    const req = httpMock.expectOne(baseUrl);
    req.flush({ count: sampleMessages.length, messages: sampleMessages });
    fixture.detectChanges();

    const header: HTMLElement = fixture.nativeElement.querySelector('h2');
    expect(header.textContent).toContain('Message History (2)');
  });

  it('renders a card per message with number, formatted timestamp, body, and char count', () => {
    fixture.detectChanges();
    const req = httpMock.expectOne(baseUrl);
    req.flush({ count: sampleMessages.length, messages: sampleMessages });
    fixture.detectChanges();

    const cards = fixture.nativeElement.querySelectorAll('.message-card');
    expect(cards.length).toBe(2);

    const firstCard = cards[0] as HTMLElement;
    expect(firstCard.querySelector('.message-number')?.textContent).toContain('+14155550123');
    expect(firstCard.querySelector('.message-timestamp')?.textContent).toContain(
      'Sunday, 17-May-20 11:18:45 UTC',
    );
    expect(firstCard.querySelector('.message-body')?.textContent).toContain('Hello there');
    expect(firstCard.querySelector('.message-char-count')?.textContent?.trim()).toBe('11/250');
  });

  it('counts emoji by codepoint, not UTF-16 code unit, in the per-message char count (QA report round1 N1)', () => {
    // '🎉' is a single Unicode codepoint but a UTF-16 surrogate pair
    // (raw `.length` === 2). Codepoint-accurate counting must report 6.
    const emojiMessage: Message = {
      id: '3',
      to_number: '+14155550123',
      body: 'hi 🎉🎉🎉',
      status: 'sent',
      external_sid: 'FAKE-3',
      created_at: '2020-05-17T11:18:45Z',
    };

    fixture.detectChanges();
    const req = httpMock.expectOne(baseUrl);
    req.flush({ count: 1, messages: [emojiMessage] });
    fixture.detectChanges();

    expect(emojiMessage.body.length).toBe(9); // UTF-16 units: 'hi ' (3) + 3 surrogate pairs (6)
    const card: HTMLElement = fixture.nativeElement.querySelector('.message-card');
    expect(card.querySelector('.message-char-count')?.textContent?.trim()).toBe('6/250');
  });

  it('shows the empty state when there are no messages', () => {
    fixture.detectChanges();
    const req = httpMock.expectOne(baseUrl);
    req.flush({ count: 0, messages: [] });
    fixture.detectChanges();

    const empty: HTMLElement = fixture.nativeElement.querySelector('.state-message.empty');
    expect(empty).toBeTruthy();
    expect(empty.textContent).toContain('No messages sent yet.');
  });

  it('shows a loading state before the response arrives', () => {
    fixture.detectChanges();
    const loading: HTMLElement = fixture.nativeElement.querySelector('.state-message.loading');
    expect(loading).toBeTruthy();

    const req = httpMock.expectOne(baseUrl);
    req.flush({ count: 0, messages: [] });
  });

  it('shows an error state when the fetch fails', () => {
    fixture.detectChanges();
    const req = httpMock.expectOne(baseUrl);
    req.error(new ProgressEvent('error'), { status: 500, statusText: 'Server Error' });
    fixture.detectChanges();

    const error: HTMLElement = fixture.nativeElement.querySelector('.state-message.error');
    expect(error).toBeTruthy();
  });
});
